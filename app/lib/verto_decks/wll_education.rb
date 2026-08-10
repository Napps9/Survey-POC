module VertoDecks
  # World's Largest Lesson — Transforming Education. One programme, collected
  # two ways: on paper in classrooms and digitally through the player.
  #
  # ── One Verto, two collection modes ───────────────────────────────────────
  # The two exports are NOT two halves of one deck. Paper ran 15 cards, digital
  # ran 24; digital asks three questions paper never did, and answer keys are
  # POSITIONAL, so replaying both against either file's own card order would
  # shift every subsequent answer onto the wrong question.
  #
  # What makes them one Verto anyway is that they share eighteen questions
  # asked the same way of the same population — the comparison between the two
  # cohorts is the interesting part, and splitting them into two Vertos throws
  # it away. So this deck is the UNION, in one fixed order, and a file simply
  # has no column for the questions it didn't ask: those respondents have no
  # answer there, which is true. `collection_mode` (see the subclasses) keeps
  # the two halves distinguishable, and Ask Verto publishes it as a segment.
  #
  # ── What is deliberately not here ─────────────────────────────────────────
  # Paper has a column headed "For those who choose other for type of school
  # (freeform)". It does not contain that. The field team repurposed it to tag
  # each paper batch with its country and distribution partner, and 1,854 of
  # its cells hold things like "Pakistan- TeachForAll", transcription notes,
  # a street address and, in one cell, a list of eleven pupils' names. It is
  # batch metadata wearing a question's header — importing it would put names
  # into a corpus that exists to be quoted. It is left out.
  class WllEducation < Base
    ORG_NAME    = "World's Largest Lesson".freeze
    ORG_SLUG    = "wll".freeze

    # "Skipped" is a literal cell value in the paper file — 324 of them, in
    # eight columns, including mixed into multi-answer cells ("Skipped ||| A
    # lot more than other people"). It means the transcriber found the question
    # blank, so it is not an answer.
    SKIPPED = [ "Skipped" ].freeze

    MOODS = [ "Happy", "Excited", "Calm", "Tired", "Nervous" ].freeze

    LESSON_PLACES = [
      "In person classes in school",
      "Hybrid classes - learning in school and also having lessons online at home",
      "Online classes at home",
      "Other (please type)"
    ].freeze

    # The card-sort statements, exactly as the export spells them — straight
    # apostrophes throughout, unlike the UNYouth export's curly ones.
    RETURN_STATEMENTS = [
      "I was happier learning at home",
      "I have a device of my own to learn with",
      "I have fallen behind my class because of the closures",
      "I missed being with other people while my school was closed",
      "Everyone in my class has come back to school",
      "I feel anxious being back at school",
      "I have the time and support in school that I need to catch up",
      "I'm happy to be back at school"
    ].freeze

    ENJOY_SCHOOL = [
      "A lot less than other people", "Less than other people", "The same as other people",
      "More than other people", "A lot more than other people"
    ].freeze

    LEARNING_STYLES = [
      "Sitting and listening to my teachers", "Working in a group with others",
      "Making and experimenting", "Solving real world problems",
      "Presenting and performing", "Being creative and playful",
      "On my own", "Using social media", "Online", "Other (please type)"
    ].freeze

    # Both "reason for school" questions offer the same five, plus the digital
    # file's text-less "Other" bucket — the platform exported the label but not
    # what anyone typed, so it is an option like any other, with no free text
    # behind it.
    SCHOOL_REASONS = [
      "To enjoy learning and become a great learner for the future",
      "To have a good career",
      "To understand who I am, what I want and become a member of my community",
      "To understand the world and help make it better",
      "To get good grades and pass exams",
      "Other (please type)"
    ].freeze

    CONTRIBUTES = [
      "Yes all the time", "Only sometimes", "No but I would like to",
      "No one would listen to me if I tried", "I don't know"
    ].freeze

    CHANGE_SKILLS = [
      "Teamwork and kindness", "Courage and determination", "Listening and communicating",
      "Creativity and curiosity", "Strength and resilience"
    ].freeze

    # A real 0–10 scale, stored as the eleven values the export actually holds.
    #
    # It used to be cut into the five stops a range card has, which threw seven
    # of every eleven distinctions away and made NPS itself uncomputable from
    # the database — 2,420 people who said 10 and 53 who said 9 became one
    # number. The export writes its endpoints as strings ("0- No" with no space
    # before the dash, "10 - Yes" with spaces both sides) and 1–9 as bare
    # integers; all eleven are reproduced here exactly.
    SKILLS_TAUGHT = [
      "0- No", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10 - Yes"
    ].freeze

    DATA_LITERACY = [ "I don't know what data is", "Never", "Sometimes", "All the time" ].freeze

    LEARNING_TO = [
      "Be creative and generate new ideas", "Work with others to solve problems",
      "Protect the planet and tackle climate change",
      "Develop digital skills like programming and coding",
      "Look after your mental health and well-being", "Analyse and use data",
      "Manage money and a budget", "Understand different cultures"
    ].freeze

    # A three-point sufficiency scale, not a yes/no. Mapping it onto tap_card's
    # yes/no/unsure would publish "yes" where a respondent said "not enough".
    SUFFICIENCY = {
      "Nothing at all"    => "How much are you learning to… (decision - Nothing at all)",
      "Not enough"        => "How much are you learning to… (decision - Not enough)",
      "More than enough"  => "How much are you learning to… (decision - More than enough)"
    }.freeze

    COLLABORATORS = [
      "Teachers", "Government and politicians", "A family member or caregiver",
      "Friends or other young people", "Business people, charities and institutions"
    ].freeze

    SCHOOL_TYPES = [ "Public school", "Private school", "Religious school", "Other" ].freeze

    AREA_TYPES = [ "Urban (a city)", "Suburban ( a town or village)", "Rural (Countryside)", "Other" ].freeze

    def org_name    = ORG_NAME
    def org_slug    = ORG_SLUG
    def admin_email = "admin@wll.example"
    def title       = "WLL Transforming Education"
    def verto_slug  = "wll-transforming-education"
    def non_answers = SKIPPED

    def brand_palette
      { "primary" => "#0CA7FF", "cta" => "#FFCC00", "bg" => "#111A2E" }
    end

    def survey_attributes
      {
        theme: "education, learning and student voice",
        audience_age: "youth",
        key_insight: "What school is for, what it teaches, and what young people would change about it.",
        show_results_comparison: true,
        compare_note: "See how your answers compare with everyone else who took part."
      }
    end

    # rubocop:disable Metrics/MethodLength -- the deck IS a list; splitting it
    # would hide the one thing that matters about it, which is the order.
    def specs(importer)
      specs = [ welcome(importer) ]

      specs << importer.pick_one_spec("How are you feeling today?", MOODS,
        "How are you feeling today? (range)")

      specs << importer.pick_one_spec("Where do you currently have your school lessons?", LESSON_PLACES,
        "Where do you currently have your school lessons? (pickOne)")

      specs << importer.decision_spec("Which of the following statements do you agree/disagree with?",
        RETURN_STATEMENTS,
        yes:    "Which of the following statements do you agree/disagree with (decision - Yes)",
        no:     "Which of the following statements do you agree/disagree with (decision - No)",
        unsure: "Which of the following statements do you agree/disagree with (decision - I don't know)")

      specs << importer.range_spec("I enjoy school…", ENJOY_SCHOOL, "I enjoy school… (range)")

      specs << importer.pick_many_spec("I do my best learning…", LEARNING_STYLES,
        "I do my best learning ... (pickMany)")

      specs << importer.pick_one_spec("The main reason I go to school is…", SCHOOL_REASONS,
        "The main reason I go to school is... (pickOne)")

      specs << importer.pick_one_spec("Why do you think adults want you to go to school?", SCHOOL_REASONS,
        "Why do you think adults want you to go to school? (pickOne)")

      specs << importer.open_text_spec("What is one thing that your school should stop doing?",
        "What is one thing that your school should stop doing? (freeform)")

      specs << importer.pick_one_spec("Do you contribute to making education better in your school?",
        CONTRIBUTES, "Do you contribute to making education better in your school? (netPromoter)")

      # The header carries a literal "&nbsp;" — it is part of the column's name
      # in both files, not a rendering artefact.
      specs << importer.prioritise_spec("Which skills do you think you need to start change?",
        CHANGE_SKILLS, "Which skills do you think you need to start change?&nbsp; (priority)")

      specs << importer.pick_one_spec("Are you learning these skills in school?", SKILLS_TAUGHT,
        "Are you learning these skills in school? (netPromoter)")

      specs << importer.pick_one_spec("Have you learned about data and how to use it in school?",
        DATA_LITERACY, "Have you learned about data and how to use it in school? (range)")

      specs.concat(importer.pile_specs("How much are you learning to…", LEARNING_TO, SUFFICIENCY))

      specs << importer.open_text_spec("I believe the purpose of school should be…",
        "I believe the purpose of school should be... (freeform)")

      specs << importer.open_text_spec("If you could reinvent one big thing about your education, what would it be?",
        "If you could reinvent one big thing about your education, what would it be? (freeform)")

      specs << importer.pick_many_spec("Who would you most like to work with to help you create some of these changes?",
        COLLABORATORS, "Who would you most like to work with to help you create some of these changes? (pickMany)")

      specs << importer.country_spec("Where do you live?",
        importer.column("Where do you live? Type your country &amp; choose from the drop down (location)",
                        "Where do you live? Type and choose from the drop down (location)"))

      specs << importer.age_spec("How old are you?", "How old are you? (age)")

      specs << importer.pick_one_spec("What is your gender?", VertoCsvImporter::GENDER_OPTS,
        "What is your gender? (gender)", demographic: true, demo: :gender)

      specs << importer.pick_one_spec("What type of school do you go to?", SCHOOL_TYPES,
        "Type of school? (education)")

      # Tagged "(gender)" by the source platform — the second column in both
      # files to claim that tag. Dispatching on the type suffix rather than the
      # question would file settlement type as gender, so it never is.
      specs << importer.pick_one_spec("What type of area do you live in?", AREA_TYPES,
        "What type of area do you live in? (gender)")

      specs
    end
    # rubocop:enable Metrics/MethodLength

    private

    def welcome(_importer)
      { card: { "type" => "welcome_card", "title" => title,
                "text" => "Tell us what school is for, what it teaches you, and what you'd change. " \
                          "Anonymous, a few minutes." },
        get: ->(_row, _source) { nil } }
    end
  end
end
