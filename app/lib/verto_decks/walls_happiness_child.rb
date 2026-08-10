module VertoDecks
  # The children's flow of the Happiness Project: fielded Feb–Mar 2022, arriving
  # as per-country workbooks (Brazil, India, Indonesia so far) committed as one
  # combined export — same shape as the adult flow, with each row's provenance
  # in its Country column. The workbook's two mid-deck static pages ("Great
  # choice! We love getting something nice!") are encouragement, not questions,
  # and are left out — a card with nothing to answer is a card respondents drop
  # out on.
  #
  # ── Where the fielded survey corrects the workbook ────────────────────────
  # This deck was first written from the design workbook, before any answers
  # existed. The export is the authority on what was actually asked:
  #   * "I was the happiest recently when I was…" was designed as a ranking but
  #     FIELDED as an ordinary multi-pick — most respondents chose one option
  #     and the tail runs to eight, so counts are the honest reading and it is
  #     a select_many here, not a prioritise;
  #   * option wordings: "Someone in my family", "Playing videogames", and the
  #     two "No…" answers of the school question as full sentences;
  #   * the tools list's fielded spellings (see TOOLS in the parent).
  # Each swipe question exports a third "(decision - )" pile column, provably
  # empty in every file — unclaimed, exactly as in the adult flow.
  class WallsHappinessChild < WallsHappiness
    def title      = "The Happiness Project — Children"
    def verto_slug = "walls-happiness-children"
    def audience   = "youth"

    # The child flow's agreement scale spells its middle stop "I'm unsure"
    # where every other scale says "Unsure". Kept as fielded.
    CHILD_AGREE = [ "Strongly disagree", "Disagree", "I'm unsure", "Agree", "Strongly agree" ].freeze

    # rubocop:disable Metrics/MethodLength -- the deck IS a list, and the order
    # of that list is the positional key every answer is stored under.
    def specs(importer)
      [
        importer.card_spec(welcome(title)),

        importer.pick_one_spec("Which super power would you use to make someone happy?",
          [ "Spend time with them", "Talk about their feelings", "Buy them something nice",
            "Make them laugh" ],
          "Which superpower would you use to make someone happy? (pickOne)"),

        importer.pick_many_spec("When you want to share a happy moment, what do you do?",
          [ "Talk with Friends", "Speak to my family", "Write in my journal", "Share it on social media",
            "Talk to my teacher", "Nothing, I keep things to myself", "All of the above, I tell everyone",
            "Other" ],
          "When you want to share a happy moment, what do you do? (pickMany)"),

        importer.pick_many_spec("I was the happiest recently when I was…",
          [ "Having fun with my friends and family", "Having free time", "Studying and getting good grades",
            "Playing sports", "Playing videogames", "Being creative and using my imagination",
            "Helping others", "Other" ],
          "I was the happiest recently when I was… (pickMany)"),

        importer.range_spec("\"If you're happy as a child, you'll be happy as an adult\"", AGREE,
          "\"If you're happy as a child, you'll be happy as an adult\" (netPromoter)"),

        importer.pick_many_spec("What are the top 3 things that you think make adults happy?",
          [ "Spending time with friends and family", "Having free time", "Working", "Hobbies and sports",
            "More followers on social media", "Having lots of money", "Helping others", "Other" ],
          "What are the top 3 things that you think make adults happy? (pickMany)"),

        importer.pick_one_spec("When you're concerned or upset, who is the first person you turn to?",
          [ "Friends", "Someone in my family", "My journal", "Social Media", "My pet", "A teacher",
            "I keep things to myself", "Other" ],
          "When you're concerned or upset, who is the first person you turn to? (pickOne)"),

        importer.range_spec("How often do you spend time playing with the adults that live with you?",
          PLAY_FREQUENCY,
          "How often do you spend time playing with the adults that live with you? (range)"),

        importer.decision_spec("Which of these spoils your happiness?",
          [ "Having school online", "Not seeing my friends and family in person",
            "My family members not being able to work", "When someone I love is not feeling well",
            "The climate crisis", "The news", "Social Media", "Pressure from school", "Feeling lonely" ],
          yes: "Which of these spoils your happiness? (decision - Yes)",
          no:  "Which of these spoils your happiness? (decision - No)"),

        importer.pick_many_spec("Let's think about the future for a moment. What are you most worried " \
                                "will make you unhappy?",
          [ "The climate crisis", "News and social media", "Worry about getting a job",
            "Worry about my family", "Worry about money", "Not having time to play games",
            "Not having good friends", "Life will be serious all the time",
            "Being less fun, like my parents", "Not laughing as much" ],
          "Let’s think about the future for a moment. What are you most worried " \
          "will make you unhappy? (pickMany)"),

        importer.range_spec("\"I think happiness can be learnt\"", CHILD_AGREE,
          "\"I think happiness can be learnt\" (range)"),

        importer.pick_one_spec("Do you think happiness is something you should learn about at school?",
          [ "It is something I already do at school", "Yes definitely!", "I don't know",
            "No, I don't think happiness can be learnt at school",
            "No, there are other topics which are more important to learn about" ],
          "Do you think happiness is something you should learn about at school? (pickOne)"),

        importer.pick_many_spec("What tools would you like to support or manage your happiness?", TOOLS,
          "What tools would you like to support or manage your happiness? (pickMany)"),

        importer.pick_one_spec("Who do you think would benefit the most from happiness lessons?",
          [ "Children", "Adults", "Both", "Nobody" ],
          "Who do you think would benefit the most from happiness lessons? (pickOne)"),

        importer.country_spec("Where do you live?", "Country")
      ]
    end
    # rubocop:enable Metrics/MethodLength
  end
end
