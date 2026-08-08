module VertoDecks
  # The adult flow of the Happiness Project: 14 questions, several of them the
  # child flow's questions turned around — what makes CHILDREN happy, how much
  # time your children would say you play together, what you worry about on
  # their behalf. Asked of a different audience in different words, so it is a
  # sibling Verto rather than a segment of the children's one.
  class WallsHappinessAdult < WallsHappiness
    def title      = "The Happiness Project — Adults"
    def verto_slug = "walls-happiness-adults"
    def audience   = "adult"

    # rubocop:disable Metrics/MethodLength -- the deck IS a list, and the order
    # of that list is the positional key every answer is stored under.
    def specs(importer)
      [
        welcome(title),

        choice("What would you do to make someone happy?",
          [ "Make them feel loved", "Make them laugh", "Buy them something nice",
            "Give them sweet treats" ]),

        scale("\"If you're happy as a child, you'll be happy as an adult\"", AGREE),

        many("What do you think are the top 3 things that make children happy?",
          [ "Spending time with friends and family", "Having free time", "Doing well at school",
            "Hobbies and sports", "More followers on social media", "Having pocket money",
            "Being creative", "Helping others" ]),

        scale("If your children were asked about how much time they spend playing with you, " \
              "what do you think they would say?", PLAY_FREQUENCY),

        swipe("Which of these negatively affects your happiness?",
          [ "Working from home", "The idea of going back to the office",
            "Not seeing my friends and family in person", "Missing celebrations and parties with friends",
            "When someone I love is unhappy", "The climate crisis", "Social Media",
            "Pressure from work", "Feeling lonely", "The news" ]),

        choice("When you're concerned or upset, who do you turn to?",
          [ "Friends", "Someone in my family", "My journal", "I keep things to myself",
            "Social Media", "My pet", "Other" ]),

        scale("\"I think happiness can be learnt\"", AGREE),

        choice("Do you think happiness lessons should be taught in school to help build up " \
               "children's emotional resilience?",
          [ "Yes, I wish I had been taught in school", "Yes, and it should be available to adults too",
            "No strong feeling either way", "I don't think it would help",
            "It shouldn't be the schools responsibility", "There is enough emotional support in schools" ]),

        many("What tools would you like to support your children happiness?", TOOLS),

        ranked("What do you value the most for your children/students' future?",
          [ "Good education", "Financial security", "A strong network of friends",
            "Independence in life", "Owning their own home", "Finding love", "Emotional resilience" ]),

        swipe("I worry my children/students won't be happy as adults because…",
          [ "Climate change", "Political uncertainty", "Social media", "Job uncertainty",
            "Mental health issues", "Lack of emotional support" ]),

        # A two-option question. yes_no is the card built for exactly that, and
        # it is what the results screen and the corpus both expect to see.
        { "type" => "yes_no", "text" => "Do you think your childhood was happier than your children's?",
          "options" => [ "Yes", "No" ] },

        many("What can you do to help your children grow up as happy individuals?",
          [ "Secure the basics", "Good schooling", "Spend lots of quality time",
            "Let them fail & learn", "Give them right example in positive behaviours" ]),

        scale("\"I believe happiness is as important to learn about for kids as other " \
              "skills/topics like reading or math\"", AGREE)
      ].map { |card| importer.card_spec(card) }
    end
    # rubocop:enable Metrics/MethodLength
  end
end
