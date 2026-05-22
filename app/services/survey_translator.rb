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
class SurveyTranslator
  MODEL      = "claude-sonnet-4-6"
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
    - Keep translations concise to fit UI constraints: question text short
      (aim under ~70 characters), option labels short (aim under ~20 characters).
    - Preserve numbers, and leave proper nouns / brand names untranslated.
    - For scale labels (e.g. 0–10, "Not likely"…"Very likely") translate the
      words but keep any numerals as-is.

    Output via the emit_translation tool.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
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

    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [ TOOL ],
      tool_choice: { type: "tool", name: "emit_translation" },
      messages: [ { role: "user", content: user_message(source, source_locale, target) } ]
    )

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    translated = Array(deep_stringify(input_of(block))["cards"])
    align(source, translated)
  end

  private

  def user_message(source, source_locale, target)
    payload = source.each_with_index.map do |card, i|
      {
        index: i,
        type: card["type"],
        text: card["text"].to_s,
        description: card["description"].to_s,
        options: Array(card["options"]).map(&:to_s)
      }
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
      {
        "text"        => t["text"].presence || card["text"].to_s,
        "description" => t["description"].presence || card["description"].to_s,
        "options"     => src_opts.each_with_index.map { |o, j| trans_opts[j].presence || o.to_s }
      }
    end
  end

  def tool_use?(block)
    type = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
    type.to_s == "tool_use"
  end

  def input_of(block)
    raw = block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    raw.respond_to?(:to_h) ? raw.to_h : raw
  end

  def deep_stringify(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
    when Array then obj.map { |v| deep_stringify(v) }
    else obj
    end
  end
end
