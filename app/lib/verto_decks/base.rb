module VertoDecks
  # Everything about one source survey that the importer cannot work out for
  # itself: who owns it, how the Verto should describe itself, and the ordered
  # specs that reconstruct its questions.
  #
  # `specs(importer)` is handed the importer so a deck can use its spec builders
  # (range_spec, pick_one_spec, decision_spec…) rather than reimplementing the
  # answer-matching each one wires up. Spec order IS card order IS the positional
  # keys in a Response's `answers` hash, so reordering a deck after an import
  # would re-point every stored answer — append! guards against exactly that.
  class Base
    # True for a deck that exists only to be subclassed — it holds an account
    # and card helpers its siblings share, and has no questions of its own.
    # An abstract deck is not offered to `IMPORT_DECK`.
    def self.abstract? = false

    def key = self.class.name.demodulize.underscore

    # ── identity ──────────────────────────────────────────────────────────
    def org_name    = raise(NotImplementedError)
    def org_slug    = raise(NotImplementedError)
    def admin_email = raise(NotImplementedError)
    def title       = raise(NotImplementedError)
    def verto_slug  = raise(NotImplementedError)

    def brand_palette
      { "primary" => "#01EACB", "cta" => "#01EACB", "bg" => "#1C2034" }
    end

    # ── how the Verto describes itself ────────────────────────────────────
    # theme in particular reaches Ask Verto: it is what groups questions across
    # Vertos, and what the corpus offers as a suggested starting question.
    def survey_attributes
      { theme: title, audience_age: "all", key_insight: title,
        show_results_comparison: false, compare_note: nil }
    end

    # ── the deck ──────────────────────────────────────────────────────────
    def specs(_importer) = raise(NotImplementedError)

    # How this survey was collected, stamped onto every response so a Verto run
    # more than one way keeps the comparison (see AddCollectionModeToResponses).
    # nil for the ordinary case — collected through the player.
    def collection_mode = nil

    # Cell values that mean "this respondent didn't answer" rather than naming
    # an answer. Deck-declared because the same word is a legitimate option
    # somewhere else: dropping "Skipped" globally would one day silently delete
    # a real answer.
    def non_answers = [].freeze
  end
end
