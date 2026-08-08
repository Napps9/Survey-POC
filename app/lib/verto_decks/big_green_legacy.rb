module VertoDecks
  # The Big Green Legacy, run with the UAE Ministry of Education: 126,895
  # sessions, 98,426 of them carrying real answers, fielded 20 October to
  # 21 November 2024 in five languages.
  #
  # ── What this export does that nothing else does ──────────────────────────
  # Its alignment is clean — it names its "Accepted Polling and Survey" column,
  # so VertoExportLayout reports shift 0 across all 49 columns. What it does
  # instead is dress its values up:
  #
  #   * 113,957 cells across 13 columns arrive inside <div>…</div>. Read as
  #     written, every affected label becomes a SECOND option and the real one
  #     reads 12.6% low — "Very important" would count 48,383 instead of 55,234.
  #   * Column 25's scale carries left-to-right marks and &nbsp;: every single
  #     "5" is "‎‎‎5&nbsp;", 70 distinct raw strings for 10 real values. Read
  #     naively the entire "5" bucket vanishes — 8,075 respondents — and the
  #     scale reports nine points instead of ten.
  #   * 1,014 cells read "University/College " with a trailing space.
  #
  # `sanitise` deals with the first; the importer's own tidy() with the rest.
  #
  # ── Three source types the platform invented ──────────────────────────────
  # `nationality`, `schoolType` and `sexuality` are outside the type vocabulary
  # every other export uses. All three behave as single-select, and the last is
  # the gender question — so, as with WLL's settlement-type column, the deck
  # keys off the QUESTION and never off the type suffix.
  #
  # ── Geography ─────────────────────────────────────────────────────────────
  # "Which location do you study in?" is UAE emirates. It is sub-national, so
  # unlike WLL's country column it cannot tag `region_country`; it is an
  # ordinary question, and the Verto contributes no country breakdown.
  class BigGreenLegacy < Base
    # Div tags, wherever they appear. Anchoring to a whole-cell wrap looks
    # tidier and misses the cells where an invisible mark sits outside the tag
    # ("‎<div>‎ 10</div>"), which is most of the ones that matter.
    DIV = %r{</?div>}i

    IMPORTANCE = [
      "Not important", "Slightly important", "Moderately important", "Important", "Very important"
    ].freeze

    LEARNING_CHANNELS = [
      "In classes at school or university", "On social media",
      "In school assemblies or university events", "From outdoor activities",
      "Outside of school or university activities", "In clubs at my school or university",
      "I am not learning about climate change"
    ].freeze

    # The workbook defines a seventh option that no respondent ever chose. It
    # stays: the question offered it, and a deck that lists only what was picked
    # is a record of the answers rather than of the question.
    TOPICS = [
      "The causes of climate change", "The impact of climate change on nature",
      "How to live a sustainable life", "How to reduce energy use",
      "How climate change impacts everyone differently", "How to adapt to climate change",
      "I am not learning about any of these topics."
    ].freeze

    # 1–10, as integers. Not a Playverto range: that card holds five stops, and
    # cutting ten into five would throw half the distinctions away.
    PREPAREDNESS = (1..10).map(&:to_s).freeze

    WORRY = [ "Not at all worried", "Not very worried", "Somewhat worried", "Very worried" ].freeze

    # "I don't know" is off the scale, which is why this is a choice and not a
    # range — an index for it would be a position it does not have. Straight
    # apostrophe, as the export writes it in this column.
    INTEREST = [
      "Not interested", "A little interested", "Interested", "Very interested", "I don't know"
    ].freeze

    EMIRATES = [
      "Abu Dhabi (Abu Dhabi)", "Abu Dhabi (Al Ain)", "Abu Dhabi (Al Dhafra)", "Dubai",
      "Sharjah", "Sharjah East", "Khor Fakkan", "Ajman", "Umm Al Quwain",
      "Ras Al Khaimah", "Fujairah", "This doesn’t apply to me"
    ].freeze

    PLACES = { "Inside" => 34, "Unsure" => 33, "Outside" => 32 }.freeze
    ACTIVITIES = [ "Studying", "Being with friends", "Exercise and playing sports" ].freeze

    HOPE = [ "Not hopeful", "Somewhat hopeful", "Hopeful", "Very hopeful" ].freeze

    # Straight apostrophe here and curly on the future-generations question.
    # Both are reproduced exactly: the export means the same thing twice and
    # spells it differently, and matching folds the difference without storing it.
    PERSONAL_IMPACT = [ "Not at all", "Only a little", "A moderate amount", "A great deal", "I don't know" ].freeze
    FUTURE_IMPACT   = [ "Not at all", "Only a little", "A moderate amount", "A great deal", "Don’t know" ].freeze

    CONFIDENCE = [
      "make sustainable choices?", "find resources to increase your knowledge?",
      "use apps or online tools as part of your climate action?",
      "use past solutions to protect the environment?",
      "understand and use data about climate change and the environment?",
      "respond to climate emergencies?", "think of new solutions for climate change?",
      "convince others to take action?"
    ].freeze

    LEARNT = [
      "I want to take action for the environment",
      "I believe the world has the solutions for climate change",
      "I know what I can do to help protect the environment",
      "I worry about people who are impacted by climate change",
      "I think climate change impacts everyone in my country equally",
      "I worry we won't do enough to stop climate change"
    ].freeze

    SCHOOL_TYPES = [
      "Public School", "Private School", "Applied Technology School",
      "Homeschooled", "University/College", "Other"
    ].freeze

    FREQUENCY = [
      "Every day", "Once a week", "Once a month", "A few times a year",
      "There are no activities available to me", "I'm not interested in taking part"
    ].freeze

    AGES = [
      "Under 12", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "22 plus"
    ].freeze

    # The one localised option in the whole export, and localised
    # inconsistently — one Arabic respondent got the English string and two
    # English respondents got the Arabic one — so these are matched
    # language-agnostically rather than keyed on the Language column.
    AGE_ALIASES = {
      "تحت 12" => "Under 12", "Moins de 12 ans" => "Under 12",
      "12岁以下" => "Under 12", "menores de 12 años" => "Under 12"
    }.freeze

    GENDERS = [ "Female", "Male" ].freeze

    def org_name    = "UAE Ministry of Education"
    def org_slug    = "moe-uae"
    def admin_email = "admin@moe-uae.example"
    def title       = "The Big Green Legacy"
    def verto_slug  = "big-green-legacy"
    def option_aliases = AGE_ALIASES

    def sanitise(value) = value.to_s.gsub(DIV, "")

    def brand_palette
      { "primary" => "#01EACB", "cta" => "#A3E635", "bg" => "#0F2018" }
    end

    def survey_attributes
      {
        theme: "climate change, the environment and taking action",
        audience_age: "youth",
        key_insight: "What young people are taught about climate change, what they can do about it, " \
                     "and what they would like to learn next.",
        show_results_comparison: true,
        compare_note: "See how your answers compare with everyone else who took part."
      }
    end

    # rubocop:disable Metrics/MethodLength -- the deck IS a list, and the order
    # of that list is the positional key every answer is stored under.
    def specs(importer)
      specs = [ importer.card_spec({ "type" => "welcome_card", "title" => title,
                                     "text" => "Tell us what you are learning about climate change, " \
                                               "what you already do, and what you would change. " \
                                               "Anonymous, a few minutes." }) ]

      specs << importer.range_spec("How important is the issue of climate change to you personally?",
        IMPORTANCE, "How important is the issue of climate change to you personally? \n (range)")

      specs << importer.pick_many_spec("How do you learn about climate change or the environment?",
        LEARNING_CHANNELS, "How do you learn about climate change or the environment? \n (pickMany)")

      specs << importer.pick_one_spec(
        "How well is your school or university preparing you to take action on climate and environmental issues? " \
        "(1 = not at all, 10 = very much so)",
        PREPAREDNESS,
        "How well is your school or university preparing you to take action on climate and environmental issues? \n (netPromoter)")

      specs << importer.pick_many_spec("What climate change or environmental topics are covered in your classes?",
        TOPICS, " What climate change or environmental topics are covered in your classes?  \n (pickMany)")

      specs << importer.pick_one_spec("Are you a UAE national?", [ "Yes", "No" ],
        " Are you a UAE national?  \n (nationality)")

      specs << importer.pick_one_spec("How worried are you about climate change?", WORRY,
        " How worried are you about climate change?  \n (netPromoter)")

      specs << importer.pick_one_spec("How interested are you in a job or training about climate change and the environment?",
        INTEREST, " How interested are you in a job or training about climate change and the environment?   \n (rating)")

      specs << importer.pick_one_spec("Which topic would you like to learn more about?",
        TOPICS.first(6), " Which topic would you like to learn more about?  \n (pickOne)")

      specs << importer.pick_one_spec("Which location do you study in?", EMIRATES,
        " Which location do you study in?  \n (location)")

      specs.concat(importer.pile_specs("Where do you prefer to do the following activity —", ACTIVITIES,
        PLACES.keys.index_with { |pile| "Where do you prefer to do the following activities? \n (decision - #{pile})" }))

      specs << importer.pick_one_spec("How hopeful are you that people can live with the impact of climate change?",
        HOPE, " How hopeful are you that people can live with the impact of climate change?  \n (range)")

      specs << importer.pick_one_spec("How much do you think climate change will impact you personally?",
        PERSONAL_IMPACT, " How much do you think climate change will impact you personally?  \n (netPromoter)")

      # No / Unsure / Yes maps exactly onto what a tap_card holds, so this one
      # stays a card sort rather than becoming eight separate questions.
      specs << importer.decision_spec("Do you feel confident that you can…", CONFIDENCE,
        no:     " Do you feel confident that you can...  \n (decision - No)",
        unsure: " Do you feel confident that you can...  \n (decision - Unsure)",
        yes:    " Do you feel confident that you can...  \n (decision - Yes)")

      specs << importer.pick_one_spec("What type of school do you go to?", SCHOOL_TYPES,
        " What type of school do you go to?  \n (schoolType)")

      specs << importer.decision_spec("When I think about what I have learnt in school or university…", LEARNT,
        no:     "When I think about what I have learnt in school or university... \n (decision - No)",
        unsure: "When I think about what I have learnt in school or university... \n (decision - Unsure)",
        yes:    "When I think about what I have learnt in school or university... \n (decision - Yes)")

      specs << importer.pick_one_spec("How often do you take part in activities to protect the environment?",
        FREQUENCY, "How often do you take part in activities to protect the environment? \n (range)")

      specs << importer.pick_one_spec("How much do you think climate change will impact future generations of people?",
        FUTURE_IMPACT, "How much do you think climate change will impact future generations of people? \n (pickOne)")

      specs << importer.open_text_spec("What actions would you like to take for climate change and the environment where you live?",
        "What actions would you like to take for climate change and the environment where you live? \n (freeform)")

      # An age BAND, not a number — "Under 12" and "22 plus" have no arithmetic
      # in them — so it is a choice, and the Verto gets no age segment.
      specs << importer.pick_one_spec("Please select your age", AGES,
        "Please select your age: \n (age)", demographic: true)

      # Tagged "(sexuality)" by the source platform. Keyed off the question.
      specs << importer.pick_one_spec("What is your gender?", GENDERS,
        " What is your gender?  \n (sexuality)", demographic: true, demo: :gender)

      specs
    end
    # rubocop:enable Metrics/MethodLength
  end
end
