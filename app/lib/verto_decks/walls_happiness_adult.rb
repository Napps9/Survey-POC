module VertoDecks
  # The adult flow of the Happiness Project: fielded Feb–Mar 2022 across five
  # per-country workbooks (Brazil, India, Indonesia, Pakistan, Philippines),
  # committed as one combined export — the countries share one layout and one
  # Verto, and the Country column keeps each row's provenance.
  #
  # ── What the export taught us that the question workbook didn't ──────────
  # This deck was first written from the design workbook alone, before any
  # answers existed. The fielded survey differs in three ways, and the export
  # is the authority on all of them:
  #   * a "Why?" freeform follow-up after the childhood-happiness question
  #     that the workbook never mentioned;
  #   * the tools question's fielded options (ADULT_TOOLS below) — two more
  #     than the workbook's list, and two spellings corrected;
  #   * each swipe question exports a third, empty pile column. One of them
  #     wears a duplicate "(decision - Yes)" header that would shadow the real
  #     Yes column under CSV name lookup — both phantom columns are provably
  #     empty in every file and the duplicate-named one is dropped at
  #     conversion; "(decision - )" is kept and simply unclaimed.
  #
  # ── Unclaimed columns, deliberately ──────────────────────────────────────
  # "State" carries a sub-region label, but the product segments and maps at
  # country level (see ResolvesResultSegments), so only "Country" is bound —
  # through the same location card the player itself would have used. The
  # respondents were never asked it: the platform tagged each collection file
  # with its country, and that tag is what the card holds.
  class WallsHappinessAdult < WallsHappiness
    def title      = "The Happiness Project — Adults"
    def verto_slug = "walls-happiness-adults"
    def audience   = "adult"

    # The tools list as FIELDED — not the workbook's TOOLS. "Being creative"
    # and "Helping others" were offered here too (8,229 answers between them),
    # and the export spells "listen to" / "Projects" where the workbook wrote
    # "listen too" / "Project".
    ADULT_TOOLS = [
      "Games", "Activities", "Things to watch or listen to",
      "Projects and ideas to work in my community", "Learning from happiness experts",
      "Being creative", "Helping others", "Other"
    ].freeze

    # rubocop:disable Metrics/MethodLength -- the deck IS a list, and the order
    # of that list is the positional key every answer is stored under.
    def specs(importer)
      [
        importer.card_spec(welcome(title)),

        importer.pick_one_spec("What would you do to make someone happy?",
          [ "Make them feel loved", "Make them laugh", "Buy them something nice",
            "Give them sweet treats" ],
          "What would you do to make someone happy? (pickOne)"),

        importer.range_spec("\"If you're happy as a child, you'll be happy as an adult\"", AGREE,
          "\"If you're happy as a child, you'll be happy as an adult\" (netPromoter)"),

        importer.pick_many_spec("What do you think are the top 3 things that make children happy?",
          [ "Spending time with friends and family", "Having free time", "Doing well at school",
            "Hobbies and sports", "More followers on social media", "Having pocket money",
            "Being creative", "Helping others" ],
          "What do you think are the top 3 things that make children happy? (pickMany)"),

        importer.range_spec("If your children were asked about how much time they spend playing with you, " \
                            "what do you think they would say?", PLAY_FREQUENCY,
          "If your children were asked about how much time they spend playing with you, " \
          "what do you think they would say? (range)"),

        importer.decision_spec("Which of these negatively affects your happiness?",
          [ "Working from home", "The idea of going back to the office",
            "Not seeing my friends and family in person", "Missing celebrations and parties with friends",
            "When someone I love is unhappy", "The climate crisis", "Social Media",
            "Pressure from work", "Feeling lonely", "The news" ],
          yes: "Which of these negatively affects your happiness? (decision - Yes)",
          no:  "Which of these negatively affects your happiness? (decision - No)"),

        importer.pick_one_spec("When you're concerned or upset, who do you turn to?",
          [ "Friends", "Someone in my family", "My journal", "I keep things to myself",
            "Social Media", "My pet", "Other" ],
          "When you're concerned or upset, who do you turn to? (pickOne)"),

        importer.range_spec("\"I think happiness can be learnt\"", AGREE,
          "\"I think happiness can be learnt\" (range)"),

        # The header spells "children's" with a curly apostrophe; the cells mix
        # curly and straight for two of the options — canon() folds those, so
        # no aliases are needed.
        importer.pick_one_spec("Do you think happiness lessons should be taught in school to help build up " \
                               "children's emotional resilience?",
          [ "Yes, I wish I had been taught in school", "Yes, and it should be available to adults too",
            "No strong feeling either way", "I don't think it would help",
            "It shouldn't be the schools responsibility", "There is enough emotional support in schools" ],
          "Do you think happiness lessons should be taught in school to help build up " \
          "children’s emotional resilience? (pickOne)"),

        importer.pick_many_spec("What tools would you like to support your child's happiness?", ADULT_TOOLS,
          "What tools would you like to support your child's happiness? (pickMany)"),

        # Tagged (pickMany) by the platform, but the workbook designed it as
        # "Priority (Top 3)" and the cells bear that out: 5,733 of 5,753 hold
        # exactly three options, in the order chosen. The order is the answer.
        importer.prioritise_spec("What do you value the most for your children/students' future?",
          [ "Good education", "Financial security", "A strong network of friends",
            "Independence in life", "Owning their own home", "Finding love", "Emotional resilience" ],
          "What do you value the most for your children's/students' future? (pickMany)"),

        importer.decision_spec("I worry my children/students won't be happy as adults because…",
          [ "Climate change", "Political uncertainty", "Social media", "Job uncertainty",
            "Mental health issues", "Lack of emotional support" ],
          yes: "I worry my children/students won't be happy as adults because of... (decision - Yes)",
          no:  "I worry my children/students won't be happy as adults because of... (decision - No)"),

        yes_no_spec(importer, "Do you think your childhood was happier than your children's?",
          "Do you think your childhood was happier than your children’s? (range)"),

        # The follow-up the workbook never mentioned: free text on WHY your
        # childhood was or wasn't happier.
        importer.open_text_spec("Why?", "Why? (freeform)"),

        importer.pick_many_spec("What can you do to help your children grow up as happy individuals?",
          [ "Secure the basics", "Good schooling", "Spend lots of quality time",
            "Let them fail & learn", "Give them right example in positive behaviours" ],
          "What can you do to help your children grow up as happy individuals? (pickMany)"),

        importer.range_spec("\"I believe happiness is as important to learn about for kids as other " \
                            "skills/topics like reading or math\"", AGREE,
          "\"I believe happiness is as important to learn about for kids as other " \
          "skills/topics like reading or math\" (range)"),

        importer.country_spec("Where do you live?", "Country")
      ]
    end
    # rubocop:enable Metrics/MethodLength

    private

    # A two-option question on a yes_no card — the type the results screen and
    # the corpus expect for exactly this shape. The cells hold only Yes and No
    # (verified across all five files), so the extractor stores the label as
    # the player would.
    def yes_no_spec(importer, text, col)
      { card: { "type" => "yes_no", "text" => text, "options" => [ "Yes", "No" ] },
        col: col,
        get: ->(row, source) {
          v = importer.single_atom(row[source], source)
          v.nil? ? nil : { "type" => "yes_no", "value" => v }
        } }
    end
  end
end
