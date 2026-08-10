module VertoDecks
  # The children's flow of the Happiness Project: 13 questions between a
  # welcome and a thank-you. The workbook's two mid-deck static pages ("Great
  # choice! We love getting something nice!") are encouragement, not questions,
  # and are left out — a card with nothing to answer is a card respondents drop
  # out on.
  class WallsHappinessChild < WallsHappiness
    def title      = "The Happiness Project — Children"
    def verto_slug = "walls-happiness-children"
    def audience   = "youth"

    # rubocop:disable Metrics/MethodLength -- the deck IS a list, and the order
    # of that list is the positional key every answer is stored under.
    def specs(importer)
      [
        welcome(title),

        choice("Which super power would you use to make someone happy?",
          [ "Spend time with them", "Talk about their feelings", "Buy them something nice", "Make them laugh" ]),

        many("When you want to share a happy moment, what do you do?",
          [ "Talk with Friends", "Speak to my family", "Write in my journal", "Share it on social media",
            "Talk to my teacher", "Nothing, I keep things to myself", "All of the above, I tell everyone",
            "Other" ]),

        ranked("I was the happiest recently when I was…",
          [ "Having fun with my friends and family", "Having free time", "Studying and getting good grades",
            "Playing sports", "Playing video games", "Being creative and using my imagination",
            "Helping others", "Other" ]),

        scale("\"If you're happy as a child, you'll be happy as an adult\"", AGREE),

        many("What are the top 3 things that you think make adults happy?",
          [ "Spending time with friends and family", "Having free time", "Working", "Hobbies and sports",
            "More followers on social media", "Having lots of money", "Helping others", "Other" ]),

        choice("When you're concerned or upset, who is the first person you turn to?",
          [ "Friends", "Someone in family", "My journal", "Social Media", "My pet", "A teacher",
            "I keep things to myself", "Other" ]),

        scale("How often do you spend time playing with the adults that live with you?", PLAY_FREQUENCY),

        swipe("Which of these spoils your happiness?",
          [ "Having school online", "Not seeing my friends and family in person",
            "My family members not being able to work", "When someone I love is not feeling well",
            "The climate crisis", "The news", "Social Media", "Pressure from school", "Feeling lonely" ]),

        many("Let's think about the future for a moment. What are you most worried will make you unhappy?",
          [ "The climate crisis", "News and social media", "Worry about getting a job",
            "Worry about my family", "Worry about money", "Not having time to play games",
            "Not having good friends", "Life will be serious all the time",
            "Being less fun, like my parents", "Not laughing as much" ]),

        # The workbook writes this scale's middle stop as "I'm unsure" here and
        # "Unsure" everywhere else. Kept as written — it is what the child sees.
        scale("\"I think happiness can be learnt\"",
          [ "Strongly disagree", "Disagree", "I'm unsure", "Agree", "Strongly agree" ]),

        choice("Do you think happiness is something you should learn about at school?",
          [ "It is something I already do at school", "Yes definitely!", "I don't know",
            "No I don't think happiness can be learnt at school",
            "No, other topics are more important to learn about" ]),

        many("What tools would you like to support or manage your happiness?", TOOLS),

        choice("Who do you think would benefit the most from happiness lessons?",
          [ "Children", "Adults", "Both", "Nobody" ])
      ].map { |card| importer.card_spec(card) }
    end
    # rubocop:enable Metrics/MethodLength
  end
end
