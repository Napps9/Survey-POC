module VertoDecks
  # Ashoka — You Are Nature. Nature connection and youth changemaking, fielded
  # from September 2025 and still collecting (the design aims at 5,000
  # responses from 10 countries; the export holds 2,952 so far). Multilingual —
  # en, es, pt and sw respondents — with every closed answer exported as its
  # canonical English label, so no translation aliases are needed.
  #
  # ── What the export dictates ──────────────────────────────────────────────
  # The agree/disagree battery ran TWICE — nature identity, then personal
  # development — with byte-identical column names; the conversion suffixes
  # the second battery's columns "(personal development)" because CSV name
  # lookup would otherwise silently read the first battery for both. Each
  # battery is a three-pile card sort (Disagree/Neutral/Agree), which is
  # pile_specs territory: a per-statement multiple_choice, never a yes/no.
  #
  # The two matrix blocks differ in shape and are modelled differently on
  # purpose: the nature matrix offers SIX stops (its scale includes "Unsure"),
  # which range cards cannot hold, so each statement is a multiple_choice that
  # stores the label; the WHO-5-style wellbeing matrix is a clean five-stop
  # frequency scale and stays a range.
  #
  # The freeform column arrived as the player's per-locale transcription JSON;
  # the conversion extracted each respondent's own words (their row's language
  # first), and the untouched multi-locale record survives in the unclaimed
  # Transcriptions column. Dwell-time, device and browser columns are
  # analytics, not answers — unclaimed.
  class YouAreNature < Base
    ORG_NAME = "Ashoka".freeze
    ORG_SLUG = "ashoka".freeze

    CONNECTED = [ "Not connected", "A little connected", "Somewhat connected",
                  "Connected", "Very connected" ].freeze

    NATURE_TIME = [
      "Never – I don't spend time in nature", "Rarely – A few times a year",
      "Sometimes – About once a month", "Often – A few times a month",
      "Very often – Every week or more"
    ].freeze

    # The nature matrix's scale has six stops — "Unsure" alongside the five
    # frequencies — so these cards store labels, not range indices.
    MATRIX_FREQ = [ "Never", "Rarely", "Sometimes", "Often", "Always", "Unsure" ].freeze
    WHO5_FREQ   = [ "Never", "Rarely", "Sometimes", "Often", "Always" ].freeze

    NATURE_MATRIX = [
      "feel more confident in myself", "connect with people who are different to me",
      "feel like I belong", "care more about the planet",
      "understand how nature connects to my life", "stay calm when things get hard",
      "believe I can make a difference", "feel hopeful for the future of the planet"
    ].freeze

    PLACES = [
      "In parks, beaches, or green spaces", "In the countryside, by rivers, or in wild areas",
      "Hiking, camping, or outdoor adventures", "Walking or commuting through nature",
      "In gardens or farms", "Playing sports outdoors",
      "Outside where I live or study (yard, street, school grounds)",
      "At school (playing or doing nature activities)",
      "Watching nature shows or reading about nature", "Other (tell us!)"
    ].freeze

    BARRIERS = [
      "Not enough free time", "Too much homework", "The weather",
      "I'm not allowed to go alone", "No nature nearby", "Pollution",
      "No one to play with", "Too many cars or traffic", "No way to get there",
      "Nothing fun to do", "It doesn't feel safe", "I'd rather play online",
      "Other (tell us!)"
    ].freeze

    # Fielded statements, exactly — including "I feel bored in nature" with no
    # full stop, unlike its nine siblings.
    NATURE_STATEMENTS = [
      "I feel comfortable in nature.", "I feel bored in nature",
      "I feel upset when the surrounding nature is unhealthy.",
      "My experiences in nature have shaped my identity.",
      "I actively take care of nature.", "I can tell if the surrounding nature is healthy.",
      "I can interact with nature confidently.",
      "I feel responsible for protecting nature for future generations.",
      "I am curious about how nature works.", "I have a deep sense of unity with nature."
    ].freeze

    DEVELOPMENT_STATEMENTS = [
      "I try new things, even if they're hard.", "I can calm down when I feel upset.",
      "I can explain what I think and feel.", "I solve problems on my own.",
      "I understand how others feel and try to help.",
      "I enjoy talking and listening to others.", "I keep going, even when things are tough.",
      "I share my ideas when working with others.", "I like learning about the world."
    ].freeze

    AGREEMENT = "Please indicate if you agree or disagree with each statement below.".freeze

    NATURE_PILES = {
      "Disagree" => "#{AGREEMENT} (decision - Disagree)",
      "Neutral"  => "#{AGREEMENT} (decision - Neutral)",
      "Agree"    => "#{AGREEMENT} (decision - Agree)"
    }.freeze

    DEVELOPMENT_PILES = {
      "Disagree" => "#{AGREEMENT} (personal development) (decision - Disagree)",
      "Neutral"  => "#{AGREEMENT} (personal development) (decision - Neutral)",
      "Agree"    => "#{AGREEMENT} (personal development) (decision - Agree)"
    }.freeze

    HELP_DECIDE = [ "Very little", "A little", "A moderate amount",
                    "Quite a bit", "A great deal" ].freeze
    ACTION_FREQ = [ "Never", "Rarely", "Sometimes", "Often", "Every day" ].freeze

    AREAS = [
      "Mostly buildings and roads, with very little nature around",
      "City or town with parks, trees, or other green spaces nearby",
      "Small town or village with lots of nature close by",
      "Countryside or rural area, surrounded by natural places"
    ].freeze

    WHO5 = [
      "I have felt cheerful and in good spirits.", "I have felt calm and relaxed.",
      "I have felt active and full of energy.", "I woke up feeling fresh and well-rested.",
      "My daily life has been filled with things that interest me.",
      "The people around me care about creating positive change."
    ].freeze

    def org_name    = ORG_NAME
    def org_slug    = ORG_SLUG
    def admin_email = "admin@ashoka.example"
    def title       = "You Are Nature"
    def verto_slug  = "you-are-nature"

    def brand_palette
      { "primary" => "#7ED957", "cta" => "#01EACB", "bg" => "#14251C" }
    end

    def survey_attributes
      {
        theme: "nature connection and youth changemaking",
        audience_age: "youth",
        key_insight: "How connected young people feel to nature, what blocks them, " \
                     "and whether that connection powers wellbeing and action.",
        show_results_comparison: true,
        compare_note: "See how your answers compare with everyone else who took part."
      }
    end

    # Three cells carry a '">'-prefixed fragment of spreadsheet markup stuck to
    # a statement, and the pickMany "Other (tell us!)" label drags an empty
    # transcription bracket (" []") behind it. Neither is an answer.
    #
    # The battery columns are also wrapped: this platform writes each decision
    # cell as a ONE-ELEMENT JSON array — ["a ||| b"] — which tap_value's JSON
    # parse handles but the pile machinery's shared atom-splitting does not,
    # leaving every cell's first and last statement with a bracket-quote stuck
    # to it and quietly unmatched. Unwrapped here instead; no other cell this
    # deck splits begins with a bracketed quote, and the location column never
    # passes through sanitise at all.
    def sanitise(value)
      v = value.to_s.gsub(/\\?">/, "").gsub(" []", "")
      v = v.sub(/\A\["/, "").sub(/"\]\z/, "")
      v == "[]" ? "" : v
    end

    # rubocop:disable Metrics/MethodLength -- the deck IS a list, and the order
    # of that list is the positional key every answer is stored under.
    def specs(importer)
      specs = [ importer.card_spec(welcome) ]

      specs << importer.rating_spec("Do you feel connected to nature or natural places?", CONNECTED,
        "Do you feel connected to nature or natural places? (rating)")

      specs << importer.pick_many_spec("Where do you usually feel connected to nature?", PLACES,
        "“Where do you usually feel connected to nature?” (pickMany)")

      specs << importer.range_spec("How often do you do things in nature that you enjoy?", NATURE_TIME,
        "How often do you do things in nature that you enjoy? (range)")

      NATURE_MATRIX.each do |statement|
        specs << importer.pick_one_spec("Spending time in nature helps me… #{statement}", MATRIX_FREQ,
          "Spending time in nature helps me... - #{statement} (matrix)")
      end

      specs << importer.pick_many_spec("What stops you from spending MORE time in nature?", BARRIERS,
        "What stops you from spending MORE time in nature? (pickMany)")

      specs.concat(importer.pile_specs(AGREEMENT, NATURE_STATEMENTS, NATURE_PILES))

      specs << importer.rating_spec("How much does your connection with nature help you think " \
                                    "about what's important or make decisions?", HELP_DECIDE,
        "How much does your connection with nature help you think about what's important " \
        "or make decisions? (rating)")

      specs.concat(importer.pile_specs(AGREEMENT, DEVELOPMENT_STATEMENTS, DEVELOPMENT_PILES))

      specs << importer.range_spec("How often do you take action that benefits nature?", ACTION_FREQ,
        "How often do you take action that benefits nature? (range)")

      WHO5.each do |statement|
        specs << importer.range_spec("Please indicate how often you've felt each of the following " \
                                     "over the past two weeks. #{statement}", WHO5_FREQ,
          "Please indicate how often you’ve felt each of the following over the past " \
          "two weeks. - #{statement} (matrix)")
      end

      specs << importer.born_spec

      specs << importer.location_spec(text: "Please select your closest city of residence.",
        col: "Please select your closest city of residence. (location)")

      specs << importer.pick_one_spec("Which of these best describes the area where you live?", AREAS,
        "Which of these best describes the area where you live? (pickOne)")

      specs << importer.open_text_spec(
        "🌿 Tell us about your favorite place to be outside — and why you love it!",
        "🌿 Tell us about your favorite place to be outside — and why you love it! (freeform)")

      specs
    end
    # rubocop:enable Metrics/MethodLength

    private

    def welcome
      { "type" => "welcome_card", "title" => title,
        "text" => "How connected do you feel to nature — and what does it do for you? " \
                  "Anonymous, a few minutes." }
    end
  end
end
