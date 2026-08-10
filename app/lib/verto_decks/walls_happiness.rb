module VertoDecks
  # Walls — The Happiness Project. Two sibling Vertos for one campaign, asking
  # the same constructs of children and of the adults around them.
  #
  # ── Questions without answers ─────────────────────────────────────────────
  # Unlike every other deck here, this one has NO export. What arrived was the
  # question-design workbook, so these decks are built (`verto:build_deck`) as
  # playable Vertos with zero responses rather than imported.
  #
  # That means they contribute nothing to Ask Verto, and shouldn't: enrolling
  # one offers it and then leaves it in the staff queue, blocked on the sample
  # floor, because a Verto with no respondents has nothing to cite. It becomes
  # citable the day it has been fielded and cleared the floor — no code change,
  # just answers.
  #
  # ── Two decks, not one ────────────────────────────────────────────────────
  # The child and adult flows mirror each other — agreement that a happy child
  # becomes a happy adult, whether happiness can be learnt, who you turn to
  # when upset, how much you play together — but they are asked of different
  # people in different words. They are separate Vertos, sharing a theme, which
  # is exactly how Ask Verto compares two audiences.
  class WallsHappiness < Base
    ORG_NAME = "Walls".freeze
    ORG_SLUG = "walls".freeze

    AGREE = [ "Strongly disagree", "Disagree", "Unsure", "Agree", "Strongly agree" ].freeze
    PLAY_FREQUENCY = [
      "Once a week", "2-3 times a week", "Every day",
      "I only play with other children", "I don't play at all"
    ].freeze
    TOOLS = [
      "Games", "Activities", "Things to watch or listen too",
      "Project and ideas to work in my community", "Learning from happiness experts", "Other"
    ].freeze

    # The two flows below are the decks; this class is the account and the card
    # vocabulary they share.
    #
    # `self ==`, not `true`: a bare `true` is INHERITED, so both flows were
    # abstract too — which quietly removed them from VertoDecks.available, and
    # therefore from the deck tests that iterate it, from `verto:preflight`, and
    # from the list `IMPORT_DECK` offers. They still imported, because fetch
    # resolves any deck by name; they were just invisible to everything that
    # asks what decks exist.
    def self.abstract? = self == VertoDecks::WallsHappiness

    def org_name    = ORG_NAME
    def org_slug    = ORG_SLUG
    def admin_email = "admin@walls.example"

    def brand_palette
      { "primary" => "#FFCC00", "cta" => "#FF1E6F", "bg" => "#1C2034" }
    end

    def survey_attributes
      {
        theme: "happiness, wellbeing and emotional learning",
        audience_age: audience,
        key_insight: "What makes people happy, what spoils it, and whether happiness can be taught.",
        show_results_comparison: true,
        compare_note: "See how your answers compare with everyone else who took part."
      }
    end

    def audience = "all"

    # ── card helpers ──────────────────────────────────────────────────────
    # The workbook's answer types, in the words it uses, mapped once here so
    # each deck below reads as its own question list and nothing else.
    private

    def welcome(title)
      { "type" => "welcome_card", "title" => title,
        "text" => "An engaging survey on happiness — what makes you happy, what gets in the way, " \
                  "and whether it's something we can learn. Anonymous, a few minutes." }
    end

    def choice(text, options)  = { "type" => "multiple_choice", "text" => text, "options" => options }
    def many(text, options)    = { "type" => "select_many", "text" => text, "options" => options }
    def scale(text, options)   = { "type" => "range", "text" => text, "options" => options }
    def swipe(text, options)   = { "type" => "tap_card", "text" => text, "options" => options }

    # The workbook distinguishes "Select 3" from "Priority (Top 3)", sometimes
    # on adjacent mirror questions. A ranking is a prioritise card, where the
    # order IS the answer; a "select 3" is an ordinary select_many — the player
    # has no per-card choice cap, so the cap lives in the question's wording
    # ("the top 3 things…") rather than in a config key nothing reads.
    def ranked(text, options) = { "type" => "prioritise", "text" => text, "options" => options }
  end
end
