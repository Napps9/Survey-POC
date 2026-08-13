require "anthropic"

# Writes the five heritage categories people in one country most commonly
# identify with, for the opt-in Heritage demographic question.
#
# The Heritage card ships a fixed nine-category global taxonomy
# (DemographicQuestions::OPTIONAL_CARDS) chosen so results compare across
# Vertos. That coarseness is the point platform-wide and the problem locally: a
# Verto run in Kenya learns nothing from a respondent picking "Black, African or
# Caribbean heritage". With a Verto's audience_country set, this service
# replaces those categories with the ones that country's own people use.
#
# The only input is a country name from WorldRegions — our own frozen ISO 3166
# table, never creator or respondent text — so nothing here needs PromptSafety
# wrapping and there is no injection surface to defend.
#
# Nothing raises. Every failure path returns nil, meaning "no verdict", and the
# caller falls back to the global nine — a creator who hits an API blip still
# gets a working Heritage question rather than an error where a card should be.
class HeritageOptionsGenerator
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 512

  # How many categories a tailored card offers. Five leaves room for the two
  # registry tail options ("Another heritage", "Prefer not to say") inside a
  # seven-option card — long enough to be recognisable, short enough to read on
  # a phone.
  WANTED = 5

  TOOL = {
    name: "emit_heritages",
    description: "Report the heritage or ethnic categories most commonly identified with in one country, " \
                 "in that country's own terms. Report an empty list when the country has no accepted set.",
    input_schema: {
      type: "object",
      properties: {
        heritages: {
          type: "array",
          # maxItems but deliberately NO minItems: an empty list is a real,
          # meaningful answer here (see the prompt's last section), and a
          # minimum would force the model to invent categories for exactly the
          # countries where inventing them does the most harm.
          maxItems: WANTED,
          items: { type: "string" },
          description: "#{WANTED} category labels, most common first, each a short noun phrase a " \
                       "respondent would pick off a list and 40 characters at most — or an EMPTY " \
                       "list when this country has no widely accepted set of heritage categories."
        }
      },
      required: %w[heritages]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You write the answer options for one survey question: "Which of these best
    reflects your heritage?", asked of people living in a particular country.

    Given a country, return the #{WANTED} heritage or ethnic categories that the
    largest shares of that country's population identify with, most common
    first.

    Where to take them from:
    - Use the categories that country's OWN census or national statistics
      office uses. They are the ones residents recognise and have answered
      before. A UK list looks nothing like a Brazilian one, and neither should
      look like an American one.
    - Use self-identification wording: what people there call themselves, and
      what official forms use to ask them. Where an official category is dated
      or contested, prefer the term that group uses for itself today.
    - Countries frame heritage differently and that is fine: some by ethnic
      group (Kenya), some by race or colour (Brazil), some by ancestral origin
      (Australia), some by a group/descent framing of their own (Malaysia's
      Malay / Chinese / Indian). Follow the country, not a template.

    Rules:
    - Exactly #{WANTED} labels, all distinct, none a subset of another.
    - 40 characters at most each. Short noun phrases, no sentences, no
      parenthetical glosses, no counts or percentages.
    - Contemporary and respectful: the terms people choose for themselves. Never
      a slur, never a colonial-era or superseded term.
    - Categories only — do not offer "Other", "Mixed", "Prefer not to say" or
      any variant. The question already carries those; a duplicate wastes a slot.
    - Do not pad with nationality ("Kenyan") where the country asks about
      ethnicity, and do not use religion unless religion genuinely is that
      country's standard heritage framing.
    - No commentary, no caveats about data quality. Just the list, via the
      emit_heritages tool.

    WHEN THERE IS NO ANSWER
    Return an EMPTY list — never a guess — when the country has no widely
    accepted set of heritage categories. That includes countries where
    collecting ethnic statistics is legally restricted (France, for one),
    countries whose statistics agency deliberately does not classify by
    ethnicity, and territories with no meaningful resident population. The
    survey then falls back to a global taxonomy, which is the right outcome:
    an invented list is worst precisely where inventing one is most harmful.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # `country` is an ISO 3166-1 alpha-2 code; `locale` the language to write the
  # labels in. Returns an array of #{WANTED} strings, or nil on any failure —
  # shape is checked by the caller (HeritageOptions), which owns the sanitising.
  def call(country:, locale: SupportedLocales::DEFAULT)
    # valid?, not name_for.present? — name_for falls back to the upcased code
    # for anything it doesn't know, so "ZZ" would have looked like a country
    # and bought a paid call to describe one that doesn't exist.
    return nil unless WorldRegions.valid?(country)

    name = WorldRegions.name_for(country)

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      # Plain string rather than a cache_control block, for SdgClassifier's
      # reason: this prefix is a few hundred tokens, under Haiku's minimum
      # cacheable size, so a marker would assert a cache that never exists.
      # HeritageOptions caches the RESULT instead, which is the saving that
      # matters here — a country's list is asked for once and reused.
      system:      SYSTEM,
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "emit_heritages" },
      messages:    [ { role: "user", content: user_message(name, locale) } ]
    )

    log_usage("HeritageOptionsGenerator", response.usage, model: MODEL)

    # No usable tool call is a failed verdict, not an empty one — truncation at
    # MAX_TOKENS, a refusal stop, or a tool input missing the key all land here.
    # nil sends the caller to the global taxonomy; [] would look like a real
    # answer of "this country has no heritages", which is never true.
    block = Array(response.content).find { |b| tool_use?(b) }
    return nil unless block

    list = deep_stringify(input_of(block))["heritages"]
    list.is_a?(Array) ? list.map(&:to_s) : nil
  rescue => e
    ErrorReporting.report("HeritageOptionsGenerator", e, country: country, locale: locale)
    nil
  end

  private

  def user_message(name, locale)
    msg = +"Country: #{name}\n\nList the #{WANTED} most commonly identified heritage categories there, most common first."
    return msg if locale.to_s == SupportedLocales::DEFAULT

    lang = SupportedLocales.find(locale)
    label = lang ? "#{lang.english_name} (#{lang.native_name})" : locale.to_s
    # Same posture as SingleQuestionGenerator: the labels are what a respondent
    # reads, so they are written in the Verto's language rather than translated
    # out of English afterwards.
    msg << "\n\nLANGUAGE: Write every label in #{label}. Do not use English."
    msg
  end
end
