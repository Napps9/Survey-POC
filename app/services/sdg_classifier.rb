require "anthropic"

# Reads a Verto's creator-authored content and decides which UN Sustainable
# Development Goals it serves — the tags that surface as "SDG n" chips on the
# dashboard, Ask Verto sources and the review queue. Runs automatically when a
# dataset is imported (VertoCsvImporter) or seeded (DemoSeeder), and from the
# sdg:backfill task for datasets that predate it.
#
# The input is only what the creator wrote: title, theme, key insight and the
# question deck. Respondent answers never enter the prompt — what a survey is
# ABOUT is fixed by its questions, not by who answered — which is also why no
# PromptSafety wrapping is needed here.
#
# Tags are enrichment, not the point: every failure path returns [] so an
# import or seed can never be blocked by a classification call.
class SdgClassifier
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 256

  # Cost hygiene for pathological decks: the subject matter of a survey is
  # established well before its 60th card, and one card's text says what it
  # asks within its first couple of hundred characters.
  MAX_CARDS       = 60
  MAX_CARD_CHARS  = 240

  TOOL = {
    name: "tag_sdgs",
    description: "Report which UN Sustainable Development Goals this survey's subject matter clearly serves. Empty list when none clearly apply.",
    input_schema: {
      type: "object",
      properties: {
        sdgs: {
          type: "array",
          items: { type: "integer", enum: UnSdgs::NUMBERS.to_a },
          description: "Goal numbers (1-17) that are a clear, primary subject of this survey. Usually 0-3. Empty when nothing clearly applies."
        }
      },
      required: %w[sdgs]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You tag surveys with UN Sustainable Development Goals. You are shown what a
    survey's creator wrote — its title, theme, stated insight and questions —
    and you report which goals that survey's subject matter clearly serves.

    The 17 goals:
    #{UnSdgs::TITLES.map { |n, t| "#{n}. #{t}" }.join("\n")}

    What each covers, in one line:
    1 poverty and basic material security · 2 hunger, food security, nutrition
    3 physical and mental health, well-being · 4 education, learning, schools
    5 gender equality, women's and girls' rights · 6 water and sanitation
    7 energy access and clean energy · 8 jobs, decent work, economic opportunity
    9 industry, innovation, infrastructure · 10 inequality between groups or places
    11 cities, housing, safe communities · 12 consumption, waste, production
    13 climate change and its impacts · 14 oceans and marine life
    15 land ecosystems, forests, biodiversity · 16 peace, justice, institutions,
    safety from violence · 17 cross-border partnership and cooperation

    RULES
    - Tag only goals that are a PRIMARY subject of the survey — something a
      whole question block is genuinely about, not an incidental mention in
      one option label.
    - 0 to 3 tags is the normal outcome. A survey is not a policy document;
      most serve one or two goals, and many serve none.
    - An empty list is a correct answer. A survey about workplace culture or
      product feedback serves no goal — do not stretch.
    - Never infer a goal from who ran the survey; judge only what it asks.

    Output via the tag_sdgs tool.
  PROMPT

  # The key is read lazily and its absence is not fatal — an import or seed on
  # a machine with no key succeeds untagged (sdg:backfill picks the rows up
  # later), same contract as OpenTextThemer's themes.
  def initialize(api_key: nil)
    @api_key = api_key || ENV["ANTHROPIC_API_KEY"]
  end

  def configured? = @api_key.present?

  def client = @client ||= build_anthropic_client(@api_key)

  # Returns sorted unique goal numbers (possibly []), and [] on any failure —
  # a tag is enrichment, and no caller should have to guard against this
  # raising mid-import.
  def call(survey:)
    return [] unless configured?

    digest = digest_for(survey)
    return [] if digest.blank?

    response = client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      [ { type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } } ],
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "tag_sdgs" },
      messages:    [ { role: "user", content: digest } ]
    )

    log_usage("SdgClassifier", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    UnSdgs.sanitize(block && deep_stringify(input_of(block))["sdgs"])
  rescue => e
    ErrorReporting.report("SdgClassifier", e, survey_id: survey.id)
    []
  end

  private

  # Creator-authored content only. Options ride along because scale labels
  # often carry the subject ("Very worried about climate change") when the
  # question stem is generic.
  def digest_for(survey)
    lines = []
    lines << "Title: #{survey.title}"            if survey.title.present?
    lines << "Theme: #{survey.theme}"            if survey.theme.present?
    lines << "Key insight sought: #{survey.key_insight}" if survey.key_insight.present?

    Array(survey.cards).first(MAX_CARDS).each do |card|
      next unless card.is_a?(Hash)
      text = card["text"].to_s.strip
      next if text.blank?

      options = Array(card["options"]).map(&:to_s).reject(&:blank?)
      line = "Q: #{text}"
      line += " [#{options.join(" / ")}]" if options.any?
      lines << line.first(MAX_CARD_CHARS)
    end

    lines.join("\n")
  end
end
