module VertoDecks
  # AAF Valparaíso, run with the Anglo American Foundation across the Valparaíso
  # region of Chile: 3,477 respondents, 3,190 of whom answered something,
  # fielded 9 September to 4 December 2025 almost entirely in Spanish.
  #
  # ── Which sheet ───────────────────────────────────────────────────────────
  # The workbook holds eight raw-data sheets of the same respondents, and only
  # `Raw_data_General` loses nothing. Each of the others is a trap:
  #
  #   * the three "removed blanks" sheets drop 298 rows, FIFTEEN of which are
  #     fully-answered respondents (eleven at 100%), and carry twelve
  #     undocumented hand edits;
  #   * `Copy of Raw_data_General` is byte-identical — importing both would
  #     double every respondent;
  #   * `Raw_data_multi` shuffled its options PER RESPONDENT, so its
  #     multi-select and card-sort headers name slots rather than answers and
  #     disagree with the sheet of record on 54% of rows.
  #
  # ── What the spreadsheet ate ──────────────────────────────────────────────
  #   * 1,117 Start dates (32%) came back ISO with the month and day swapped.
  #     See `repair_date`: read as written the campaign appears to run all year.
  #   * Every free-text answer is double-wrapped as
  #     [{"locale" : "es", "transcription" : "…"}] — with spaces around the
  #     colons. Stored raw, the average answer grows from 60 to 101 characters
  #     and every near-duplicate looks unique.
  #   * The matrix columns join a duplicated answer with a SEMICOLON rather than
  #     the export's usual separator: "Maybe;Maybe", and once ";Ready to try"
  #     with an empty left half.
  #   * Two headers lost their opening parenthesis to an &nbsp; ("…Vote in
  #     electionsmatrix)", "How worried are you about climate change?range)").
  #     Every column here is addressed by its exact header string, so that
  #     costs nothing — but a type-suffix regex would drop the climate-worry
  #     question entirely, all 2,663 answers of it.
  #
  # ── Two "Other" conventions in one file ───────────────────────────────────
  # Three columns write "Other [text]" and two write "[OTHER] text". Both are
  # kept as the option the respondent chose; the typed text rides along.
  #
  # Geography is Chilean communes — sub-national, like Big Green's emirates —
  # so this Verto tags no country either.
  class AafValparaiso < Base
    # A duplicate answer joined with a semicolon, which is this export's own
    # artefact and nothing a respondent typed.
    SEMICOLON_DUPE = /\A\s*([^;]*);\1\s*\z/
    LEADING_SEMICOLON = /\A\s*;/

    # [{"locale" : "es", "transcription" : "…"}] — note the spaces around the
    # colons, which is why this is matched rather than compared.
    TRANSCRIPTION = /"transcription"\s*:\s*"((?:[^"\\]|\\.)*)"/

    MOODS = [ "Sad", "Tired", "Bored", "Happy", "Excited" ].freeze

    TURN_TO = [
      "Talk to someone I trust", "Be alone", "Go out in nature", "Do sports",
      "Social media / watch stuff online", "Alcohol or drugs",
      "No one/nothing to turn to", "Don’t know", "Other"
    ].freeze

    AI_FEELINGS = [
      "Very excited", "Feels good/positive", "Mixed or unsure", "A bit worried", "Very worried"
    ].freeze

    ACTION_SCALE = [ "Already do", "Ready to try", "Maybe", "I don’t know", "Not for me" ].freeze

    # Header order, which is not the workbook's display order — the export puts
    # "Join a protest" first. Order here is card order, so the export's is what
    # the positional keys have to follow.
    ACTIONS = [
      "Join a protest/march/online action", "Volunteer", "Project or campaign",
      "Share ideas to improve what’s not working", "Help someone nearby",
      "Support a group/movement", "Vote in elections"
    ].freeze

    JOB_VALUES = [
      "Helping others", "Solving problems", "Being creative", "Still figuring it out",
      "Teaching / guiding", "Protecting nature", "Innovating with tech",
      "Building community", "Defending justice"
    ].freeze

    CONFIDENCE = (1..10).map(&:to_s).freeze

    CLIMATE_INTEREST = [
      "Not at all", "A little Interested", "I don't know", "Somewhat Interested", "Very Interested"
    ].freeze

    ENVIRONMENT_ACTIONS = [
      "Recycle or reuse", "Walk, bike, or use public transport", "Save water or energy at home",
      "Cut down on plastic", "Speak up or post about climate issues", "Encourage others to take action",
      "Choose eco-friendly products or brands", "Vote with climate in mind"
    ].freeze

    BARRIERS = [
      "Low motivation", "Lack of info", "Money", "Doubt it helps", "Time", "No support",
      "I don't know", "Other"
    ].freeze

    CLIMATE_WORRY = [ "Not at all worried", "Not very worried", "Somewhat worried", "Very worried" ].freeze

    INCOME = [
      "Enough, can save easily", "Enough, can save with difficulty", "Enough, but can’t save",
      "Not enough, hard to make it to month-end", "Not enough, need debt to get to month-end",
      "Don’t know / No answer", "Other"
    ].freeze

    GENDERS = [ "Female", "Male", "Prefer not to say", "Other" ].freeze

    COMMUNES = [
      "Valparaíso (provincial and regional capital)", "Viña del Mar", "Concón", "Quintero",
      "Puchuncaví", "Casablanca", "Quilpué", "Quilpué (provincial capital)", "Villa Alemana",
      "Limache", "Olmué", "Quillota (provincial capital)", "La Calera", "La Cruz", "Hijuelas",
      "Nogales", "San Antonio (provincial capital)", "Cartagena", "El Tabo", "El Quisco",
      "Algarrobo", "Santo Domingo", "San Felipe (provincial capital)", "Putaendo", "Santa María",
      "Panquehue", "Catemu", "Llaillay", "Los Andes (provincial capital)", "Calle Larga",
      "Rinconada", "San Esteban", "La Ligua (provincial capital)", "Cabildo", "Petorca",
      "Zapallar", "Arica and Parinacota", "Other"
    ].freeze

    def org_name    = "Anglo American Foundation"
    def org_slug    = "aaf-valparaiso"
    def admin_email = "admin@aaf-valparaiso.example"
    def title       = "AAF Valparaíso"
    def verto_slug  = "aaf-valparaiso"

    def brand_palette
      { "primary" => "#0CA7FF", "cta" => "#FF1E6F", "bg" => "#101A2E" }
    end

    def survey_attributes
      {
        theme: "wellbeing, work, climate and taking part",
        audience_age: "youth",
        key_insight: "What young people in Valparaíso turn to, hope for, and would change.",
        show_results_comparison: true,
        compare_note: "See how your answers compare with everyone else who took part."
      }
    end

    # An ISO date whose month and day were swapped on the way out of Excel.
    # Only ISO strings are touched — the 2,360 rows written "DD/MM/YYYY" are
    # already right, and every one of them has a day above 12, which is how the
    # swap was proved rather than guessed.
    def repair_date(value)
      match = value.to_s.strip.match(/\A(\d{4})-(\d{2})-(\d{2})\z/)
      return nil unless match

      "#{match[3]}/#{match[2]}/#{match[1]}"
    end

    def sanitise(value)
      text = value.to_s
      # A free-text answer is what the respondent wrote, not the envelope the
      # platform posted it in.
      return Regexp.last_match(1).to_s.gsub('\\"', '"').gsub("\\n", " ") if text =~ TRANSCRIPTION

      text.sub(LEADING_SEMICOLON, "").sub(SEMICOLON_DUPE) { Regexp.last_match(1) }
    end

    # rubocop:disable Metrics/MethodLength -- the deck IS a list, and the order
    # of that list is the positional key every answer is stored under.
    def specs(importer)
      specs = [ importer.card_spec({ "type" => "welcome_card", "title" => title,
                                     "text" => "Cuéntanos cómo te sientes, qué te importa y qué cambiarías. " \
                                               "Anónimo, unos minutos." }) ]

      specs << importer.range_spec("How are you feeling today?", MOODS,
        "How are you feeling today? (range)")

      specs << importer.pick_many_spec("When you feel sad or stressed — who or what do you usually turn to?",
        TURN_TO, "When you feel sad or stressed — who or what do you usually turn to? (pickMany)")

      specs << importer.range_spec("How do you feel about AI being part of your life (school, work, etc.)?",
        AI_FEELINGS, "How do you feel about AI being part of your life (school, work, etc.)? (range)")

      ACTIONS.each_with_index do |action, i|
        # The seventh header lost its opening parenthesis. Addressed exactly,
        # as every column here is.
        # …and it lost the SPACE with it: "Vote in electionsmatrix)".
        suffix = i == 6 ? "matrix)" : " (matrix)"
        specs << importer.range_spec(
          "How do these ways of taking action feel for you — in your neighbourhood? #{action}",
          ACTION_SCALE,
          "How do these ways of taking action feel for you - in your neighbourhood? - #{action}#{suffix}")
      end

      specs << importer.pick_one_spec("Apart from making money, what matters most to you in a job?",
        JOB_VALUES, "Apart from making money, what matters most to you in a job? (pickOne)")

      specs << importer.pick_one_spec(
        "On a scale of 1–10, how confident are you that you’ll find (or create) work that feels right for you?",
        CONFIDENCE,
        "On a scale of 1 - 10, How confident are you that you’ll find (or create) work that feels right for you? (netPromoter)")

      specs << importer.pick_one_spec(
        "How interested are you in training or a career helping climate change and the environment?",
        CLIMATE_INTEREST,
        "How interested are you in training or a career helping climate change and the environment? (rating)")

      specs << importer.decision_spec("What do you currently do (or try to do) to help the environment?",
        ENVIRONMENT_ACTIONS,
        no:     "What do you currently do (or try to do) to help the environment? (decision - No)",
        unsure: "What do you currently do (or try to do) to help the environment? (decision - Sometimes)",
        yes:    "What do you currently do (or try to do) to help the environment? (decision - Yes)")

      specs << importer.pick_one_spec("Why do you think people don’t do more for the planet?",
        BARRIERS, "Why do you think people don’t do more for the planet? (pickOne)")

      specs << importer.pick_one_spec("How worried are you about climate change?", CLIMATE_WORRY,
        "How worried are you about climate change?range)")

      specs << importer.open_text_spec("What do you dream about for the future — for yourself or your community?",
        "What do you dream about for the future - for yourself or your community? (freeform)")

      specs << importer.pick_one_spec("Thinking about your family’s total income, would you say that…",
        INCOME, "Thinking about your family’s total income, would you say that… (pickOne)")

      # A birth date, and 488 cells that read "Invalid date". Its day component
      # carries no information — 1,390 are the 1st and the rest are month-ends,
      # which is a month picker plus a timezone rollback — so it is stored to
      # the month, as born_value has always done.
      specs << importer.birth_month_spec("When were you born?", "When were you born? (age)")

      specs << importer.pick_one_spec("What is your gender?", GENDERS,
        "What is your gender? (gender)", demographic: true, demo: :gender)

      specs << importer.pick_one_spec("Where do you live?", COMMUNES,
        "Where do you live? (location)", demographic: true)

      specs
    end
    # rubocop:enable Metrics/MethodLength
  end
end
