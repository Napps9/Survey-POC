# A curated library of ready-made Verto decks. Picking a template instantiates
# a full, well-formed Verto instantly — no AI call, no cost — so a new org is
# never staring at a blank editor. Each template's cards use only canonical card
# types (config/card_types.yml) and the same JSON shape the generator emits, so
# an instantiated Verto is indistinguishable from a generated one and fully
# editable afterwards. Demographic questions are appended at instantiation time
# (SurveyTemplates::Instantiator), exactly as generate/import do.
#
# Template content is English by design: the instantiated Verto starts in
# English and the creator can translate it like any other Verto. Only the
# gallery *chrome* is localised (config/locales/*.yml → templates.*).
module SurveyTemplates
  module_function

  NPS_OPTIONS = (0..10).map(&:to_s).freeze

  # Each template: a stable id (used in the URL), display metadata for the
  # gallery card, the survey-level fields, and the content cards (welcome +
  # questions). Accents are drawn from the Playverto palette.
  ALL = [
    {
      id: "nps",
      name: "Net Promoter Score",
      tagline: "Measure loyalty in two questions — how likely people are to recommend you, and why.",
      emoji: "📣",
      accent: "#FF1E6F",
      theme: "customer loyalty",
      audience_age: "all ages",
      key_insight: "How likely customers are to recommend us, and what drives their score.",
      cards: [
        { "type" => "welcome_card", "text" => "Quick question about your experience",
          "description" => "Under a minute, fully anonymous — your answers help us improve." },
        { "type" => "nps", "text" => "How likely are you to recommend us to a friend or colleague?",
          "options" => NPS_OPTIONS },
        { "type" => "open_ended", "text" => "What's the main reason for your score?" },
        { "type" => "multiple_choice", "text" => "Which of these best describes you?",
          "options" => [ "New customer", "Returning customer", "Long-time customer", "Just browsing" ] }
      ]
    },
    {
      id: "csat",
      name: "Customer Satisfaction",
      tagline: "A short CSAT pulse: rate the experience, pinpoint what worked, and hear what to fix.",
      emoji: "⭐",
      accent: "#FFC93D",
      theme: "customer satisfaction",
      audience_age: "all ages",
      key_insight: "How satisfied customers are and which parts of the experience need attention.",
      cards: [
        { "type" => "welcome_card", "text" => "How did we do?",
          "description" => "A few quick taps — thanks for helping us get better." },
        { "type" => "rating", "text" => "Overall, how satisfied are you with your experience?",
          "options" => [ "Very unsatisfied", "Unsatisfied", "Neutral", "Satisfied", "Very satisfied" ] },
        { "type" => "multiple_choice", "text" => "Which part of your experience stood out most?",
          "options" => [ "Ease of use", "Speed", "Support", "Value for money", "Quality" ] },
        { "type" => "yes_no", "text" => "Would you use us again?" },
        { "type" => "open_ended", "text" => "What's one thing we could do better?" }
      ]
    },
    {
      id: "onboarding",
      name: "New User Onboarding",
      tagline: "Find out where new users get stuck and what would help them reach their first win faster.",
      emoji: "🚀",
      accent: "#0CA7FF",
      theme: "product onboarding",
      audience_age: "all ages",
      key_insight: "Where new users struggle during onboarding and what would smooth the path.",
      cards: [
        { "type" => "welcome_card", "text" => "How was getting started?",
          "description" => "You just set things up — tell us how it went while it's fresh." },
        { "type" => "rating", "text" => "How easy was it to get started?",
          "options" => [ "Very hard", "Hard", "Okay", "Easy", "Very easy" ] },
        { "type" => "multiple_choice", "text" => "Where, if anywhere, did you get stuck?",
          "options" => [ "Signing up", "Setting things up", "Finding what I needed", "Understanding how it works", "I didn't get stuck" ] },
        { "type" => "select_many", "text" => "What would have helped you get started faster? Pick all that apply.",
          "options" => [ "A guided tour", "Templates or examples", "Clearer instructions", "Live chat support", "A short video" ],
          "allow_other" => true },
        { "type" => "open_ended", "text" => "If you could change one thing about getting started, what would it be?" }
      ]
    },
    {
      id: "employee-pulse",
      name: "Employee Pulse Check",
      tagline: "A fast, anonymous read on how the team is really feeling this week — plus an eNPS.",
      emoji: "💬",
      accent: "#615BF5",
      theme: "employee engagement",
      audience_age: "working adults",
      key_insight: "How engaged and supported the team feels right now, and where to focus.",
      cards: [
        { "type" => "welcome_card", "text" => "How's it going, really?",
          "description" => "Fully anonymous — this is about making things better, not checking up." },
        { "type" => "range", "text" => "How are you feeling about work this week?",
          "options" => [ "Struggling", "Not great", "Okay", "Good", "Thriving" ] },
        { "type" => "multiple_choice", "text" => "How's your workload right now?",
          "options" => [ "Way too much", "A bit much", "About right", "A bit light", "Too light" ] },
        { "type" => "rating", "text" => "How supported do you feel by your manager?",
          "options" => [ "Not at all", "A little", "Somewhat", "Well", "Very well" ] },
        { "type" => "nps", "text" => "How likely are you to recommend this as a place to work?",
          "options" => NPS_OPTIONS },
        { "type" => "open_ended", "text" => "What's one change that would make this a better place to work?" }
      ]
    },
    {
      id: "event-feedback",
      name: "Event Feedback",
      tagline: "Capture how your event landed — the highlights, the misses, and whether they'd come back.",
      emoji: "🎉",
      accent: "#01EACB",
      theme: "event feedback",
      audience_age: "all ages",
      key_insight: "How attendees rated the event and what to change for next time.",
      cards: [
        { "type" => "welcome_card", "text" => "Thanks for coming — how was it?",
          "description" => "A couple of quick questions while it's still fresh." },
        { "type" => "rating", "text" => "How would you rate the event overall?",
          "options" => [ "Poor", "Fair", "Good", "Great", "Excellent" ] },
        { "type" => "multiple_choice", "text" => "What was the best part for you?",
          "options" => [ "The speakers", "The content", "The networking", "The venue", "The organisation" ] },
        { "type" => "yes_no", "text" => "Would you attend again?" },
        { "type" => "nps", "text" => "How likely are you to recommend this event to a colleague?",
          "options" => NPS_OPTIONS },
        { "type" => "open_ended", "text" => "What would make the next one even better?" }
      ]
    },
    {
      id: "product-market-fit",
      name: "Product-Market Fit",
      tagline: "The classic Sean Ellis test — how people would feel without you, and who values you most.",
      emoji: "🎯",
      accent: "#FF8A3D",
      theme: "product-market fit",
      audience_age: "all ages",
      key_insight: "How disappointed users would be without the product, and which segment values it most.",
      cards: [
        { "type" => "welcome_card", "text" => "Help shape where we go next",
          "description" => "A few honest answers make a real difference — thank you." },
        { "type" => "multiple_choice", "text" => "How would you feel if you could no longer use us?",
          "options" => [ "Very disappointed", "Somewhat disappointed", "Not disappointed" ] },
        { "type" => "open_ended", "text" => "What is the main benefit you get from us?" },
        { "type" => "multiple_choice", "text" => "What type of person do you think would benefit most?",
          "options" => [ "People like me", "Beginners", "Professionals", "Teams", "Not sure" ] },
        { "type" => "open_ended", "text" => "How can we improve it for you?" }
      ]
    }
  ].freeze

  ALL_BY_ID = ALL.index_by { |t| t[:id] }.freeze

  def all
    ALL
  end

  def find(id)
    ALL_BY_ID[id.to_s]
  end

  # A deep copy of a template's content cards, safe to mutate/persist (the
  # registry is frozen). Cards are pure JSON data (strings/arrays/hashes), so a
  # JSON round-trip deep-copies nested option arrays and i18n hashes cleanly.
  def cards_for(id)
    template = find(id)
    return nil unless template

    JSON.parse(JSON.generate(template[:cards]))
  end
end
