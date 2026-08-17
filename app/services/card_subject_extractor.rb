require "anthropic"

# Names each question card's depictable PHOTO SUBJECT — a 0-3 word
# photographable noun phrase ("school canteen", "bicycle", "family dinner") —
# so AssetPopulator#card_query can anchor its Pexels search on what the card
# is actually about instead of the filler-stripped keyword heuristic it falls
# back to otherwise ("How was the school canteen?" → "canteen" instead of
# "school canteen how" surviving stop-word removal). One Claude call per deck
# (not per card), run once at generation time from VertoGeneration — see
# AssetPopulator#card_query and #GEO_COMPASS/#subject_terms for why the
# extracted subject still goes through the same geography/proper-noun/charged-
# term hygiene as every other query term: this is untrusted model output,
# same as any other AI generation step.
#
# Fails safe, same posture as ImageModerator and AssetPopulator's own Pexels
# calls: an unconfigured client, an API error, or a response with no usable
# verdict even after one retry all just return `cards` UNCHANGED — the
# populator's existing keyword heuristic is the fallback either way, so a
# failure here costs relevance, never a broken generation.
class CardSubjectExtractor
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 4096

  TOOL = {
    name: "report_subjects",
    description: "Report the photographable subject for each card.",
    input_schema: {
      type: "object",
      properties: {
        subjects: {
          type: "array",
          description: "One entry per input card, in the same order.",
          items: {
            type: "object",
            properties: {
              index: { type: "integer", description: "The card's index, exactly as given in the input." },
              subject: {
                type: "string",
                description: "A 0-3 word photographable noun phrase naming what a stock " \
                             "photo for this card should show — e.g. 'school canteen', " \
                             "'bicycle', 'family dinner'. Empty string if the card names no " \
                             "single concrete, photographable subject."
              }
            },
            required: %w[index subject]
          }
        }
      },
      required: %w[subjects]
    }
  }.freeze

  SYSTEM_PROMPT = <<~SYS.freeze
    You pick a photographable SUBJECT for each survey card, for a stock-photo
    search — not a summary of the question, the concrete thing a photo of it
    would show. "How was the school canteen?" -> "school canteen", not
    "opinion" or "how was it". "Do you feel safe walking home at night?" ->
    "walking home at night", not "safety" or "feelings". A card with no
    single concrete depictable subject (an abstract rating, a yes/no about a
    feeling, a scale with no noun) gets an empty string — never guess one.
    0-3 words, always a plain noun phrase, never a full sentence, never
    punctuation. Report every card via the report_subjects tool, one entry
    per input card, same order, same index.
  SYS

  def self.configured?
    ENV["ANTHROPIC_API_KEY"].present?
  end

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # Returns `cards` with "subject" stamped onto each eligible card — every
  # question card except the demographic tail (its copy names a sensitive
  # subject that must not steer a stock-photo search, mirrors
  # AssetPopulator#theme_only_card?). Scaffolding cards (welcome/checkpoint/
  # consent_gate) are skipped too: CardTypes.question? already excludes them,
  # and AssetPopulator never queries their own copy either.
  def call(cards:)
    cards   = Array(cards).map { |c| c.is_a?(Hash) ? c.dup : c }
    targets = eligible(cards)
    return cards if targets.empty?

    out = perform_call(targets) || perform_call(targets)
    return cards unless out

    by_index = out.each_with_object({}) do |entry, h|
      idx = entry["index"]
      h[idx.to_i] = entry["subject"].to_s.strip if idx.to_s.match?(/\A\d+\z/)
    end

    cards.each_with_index do |card, idx|
      next unless card.is_a?(Hash)
      subject = by_index[idx]
      card["subject"] = subject if subject.present?
    end
    cards
  end

  private

  def eligible(cards)
    cards.each_with_index.filter_map do |card, idx|
      next unless card.is_a?(Hash)
      next unless CardTypes.question?(card["type"])
      next if card["demographic"].present?

      {
        "index"       => idx,
        "text"        => card["text"].to_s,
        "description" => card["description"].to_s,
        "options"     => Array(card["options"]).first(6)
      }
    end
  end

  # One Claude call. Returns the tool input's "subjects" array (string-keyed
  # entries), or nil if the response has no tool_use block.
  def perform_call(targets)
    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SYSTEM_PROMPT,
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "report_subjects" },
      messages: [ { role: "user", content: user_message(targets) } ]
    )
    log_usage("CardSubjectExtractor", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    return Array(deep_stringify(input_of(block))["subjects"]) if block

    Rails.logger.warn("[CardSubjectExtractor] no tool_use block in response: #{response.content.inspect.truncate(500)}")
    nil
  rescue => e
    Rails.logger.warn("[CardSubjectExtractor] call failed: #{e.class}: #{e.message}")
    nil
  end

  def user_message(targets)
    <<~MSG
      Pick a photographable subject for each card below. Return exactly
      #{targets.size} entries via report_subjects, same indexes as given.

      Cards (JSON):

      #{JSON.pretty_generate(targets)}
    MSG
  end
end
