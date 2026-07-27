require "anthropic"

# Translates a Verto's cards into another language while preserving structure
# EXACTLY: same number of cards, same option count and order per card. That
# structural invariant is what keeps results aligned across languages — answers
# are stored against the primary-language (canonical) option, and every
# translation is just a parallel label for the same positional option.
#
# Returns an array (aligned to the input cards) of:
#   { "text" => ..., "description" => ..., "options" => [...] }
# which the caller merges into each card's i18n[locale].
#
# Common Question cards are deliberately NOT skipped — a French Verto must
# present its common cards in French alongside the rest of the deck. The
# verbatim guarantee on Common Questions applies to the SOURCE language only
# (enforced by SurveyGenerator#reconcile_common_cards!); per-locale i18n
# entries are normal translations cached via TranslationCache for reuse
# across every Verto that attaches the same set into the same locale.
class SurveyTranslator
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 4096

  TOOL = {
    name: "emit_translation",
    description: "Emit translations for every card, preserving order and option counts exactly.",
    input_schema: {
      type: "object",
      properties: {
        cards: {
          type: "array",
          description: "One entry per source card, in the SAME order, with the SAME number of entries.",
          items: {
            type: "object",
            properties: {
              text: { type: "string", description: "Translated card/question text." },
              description: { type: "string", description: "Translated sub-text. Empty string if the source had none." },
              options: {
                type: "array",
                items: { type: "string" },
                description: "Translated option labels in the SAME order and SAME count as the source card. Empty array if the source had none."
              },
              pages: {
                type: "array",
                description: "Translated scenario narrative pages. One entry per source page, echoing its id EXACTLY. Empty array if the source had none.",
                items: {
                  type: "object",
                  properties: {
                    id:   { type: "string", description: "The source page's id, copied verbatim — never invent or renumber." },
                    text: { type: "string", description: "That page's translated narrative text." }
                  },
                  required: %w[id text]
                }
              },
              explanation: {
                type: "string",
                description: "Translated quiz answer explanation, shown after the respondent answers. Empty string if the source had none."
              }
            },
            required: %w[text options]
          }
        }
      },
      required: %w[cards]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You are an expert localiser for survey ("Verto") experiences. Translate the
    provided cards into the target language so they read as if originally written
    by a native speaker — natural, idiomatic, and every bit as clear and engaging
    as the source. This is not a literal word-for-word translation.

    Hard rules (these keep response data aligned across languages):
    - Output EXACTLY one entry per source card, in the SAME order.
    - For each card, output the SAME number of options, in the SAME order. Never
      add, drop, merge, split or reorder options.
    - Translate the meaning of each option faithfully; option N in your output
      must correspond to option N in the source.
    - For a card with narrative `pages`, output the SAME number of pages and
      copy each page's `id` EXACTLY as given. Match pages by id, never by
      position, and never invent, drop, merge or renumber one.
    - Translate `explanation` (the after-the-answer quiz feedback) when the
      source card has one; omit it otherwise.
    - Keep translations concise to fit UI constraints: question text short
      (aim under ~70 characters), option labels short (aim under ~20 characters).
    - Preserve numbers, and leave proper nouns / brand names untranslated.
    - For scale labels (e.g. 0–10, "Not likely"…"Very likely") translate the
      words but keep any numerals as-is.

    Output via the emit_translation tool.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # cards: array of card hashes (string keys). Returns the aligned translation
  # array described above. Falls back to source content per field/slot if the
  # model returns a malformed or mis-sized response, so the alignment invariant
  # always holds.
  def call(cards:, target_locale:, source_locale: SupportedLocales::DEFAULT)
    source = Array(cards)
    return [] if source.empty?

    target = SupportedLocales.find(target_locale)
    raise ArgumentError, "Unsupported locale: #{target_locale}" unless target

    # Cache lookup: cards we've already translated with the same source
    # content for this target skip Claude entirely.
    cached = TranslationCache.lookup_many(source, source_locale: source_locale, target_locale: target_locale)
    misses = source.each_with_index.reject { |_, i| cached[i] }
    return cached if misses.empty?

    miss_cards   = misses.map(&:first)
    miss_indices = misses.map(&:last)

    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [ TOOL ],
      tool_choice: { type: "tool", name: "emit_translation" },
      messages: [ { role: "user", content: user_message(miss_cards, source_locale, target) } ]
    )
    log_usage("SurveyTranslator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    translated_misses = align(miss_cards, Array(deep_stringify(input_of(block))["cards"]))

    # Write each miss back to the cache so the next call hits it.
    miss_cards.zip(translated_misses).each do |card, translation|
      TranslationCache.write(card, source_locale: source_locale, target_locale: target_locale, translation: translation)
    end

    # Merge cache hits + fresh translations into the source-aligned shape.
    result = cached.dup
    miss_indices.each_with_index { |orig_idx, i| result[orig_idx] = translated_misses[i] }
    result
  end

  private

  def user_message(source, source_locale, target)
    payload = source.each_with_index.map do |card, i|
      entry = {
        index: i,
        type: card["type"],
        text: card["text"].to_s,
        description: card["description"].to_s,
        options: Array(card["options"]).map(&:to_s)
      }
      # Only sent for the cards that have them, so a deck of ordinary questions
      # doesn't pay for two empty fields on every card.
      pages = Array(card["pages"]).filter_map do |p|
        { id: p["id"].to_s, text: p["text"].to_s } if p.is_a?(Hash) && p["id"].present?
      end
      entry[:pages] = pages if pages.any?
      entry[:explanation] = card["explanation"].to_s if card["explanation"].present?
      entry
    end

    <<~MSG
      Source language: #{SupportedLocales.english_name(source_locale) || source_locale}
      Target language: #{target.english_name} (#{target.native_name})

      Translate every card below into #{target.english_name}. Return exactly
      #{source.size} card entries in order, each with the same option count as
      its source. Source cards (JSON):

      #{JSON.pretty_generate(payload)}
    MSG
  end

  # Force the output to match the source's shape exactly, falling back to source
  # text/labels for anything missing or mis-sized.
  def align(source, translated)
    source.each_with_index.map do |card, i|
      t          = translated[i].is_a?(Hash) ? translated[i] : {}
      src_opts   = Array(card["options"])
      trans_opts = Array(t["options"])
      entry = {
        "text"        => t["text"].presence || card["text"].to_s,
        "description" => t["description"].presence || card["description"].to_s,
        "options"     => src_opts.each_with_index.map { |o, j| trans_opts[j].presence || o.to_s }
      }

      pages = align_pages(card, t)
      entry["pages"] = pages if pages.any?

      if card["explanation"].present?
        entry["explanation"] = t["explanation"].presence || card["explanation"].to_s
      end

      entry
    end
  end

  # Narrative pages align by id, NOT by position — a creator can reorder pages
  # after translating, and the sanitizer already stores them id-keyed for that
  # reason (Survey.sanitize_cards_images!). A page the model dropped, renamed or
  # returned empty falls back to its source text, so the page count never drifts.
  def align_pages(card, translation)
    src_pages = Array(card["pages"]).select { |p| p.is_a?(Hash) && p["id"].present? }
    return [] if src_pages.empty?

    by_id = Array(translation["pages"]).each_with_object({}) do |p, acc|
      acc[p["id"].to_s] = p["text"] if p.is_a?(Hash) && p["id"].present?
    end

    src_pages.map do |p|
      id = p["id"].to_s
      { "id" => id, "text" => by_id[id].presence || p["text"].to_s }
    end
  end

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
