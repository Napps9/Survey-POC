# Loads the canonical card-type metadata from config/card_types.yml.
#
# This is the single source of truth shared by Ruby (helpers, views) and
# JavaScript (type_panel_controller reads the same data via a JSON blob
# emitted by surveys/show.html.erb).
module CardTypes
  module_function

  # All entries, in YAML order. Returns an Array<[String, Hash<String,Object>]>.
  def all
    DATA
  end

  # Hash for one type, with String keys (e.g. "badge", "eyebrow"). Returns
  # an empty hash for unknown types so callers can safely chain `.dig`.
  def meta(type)
    DATA_BY_KEY[type.to_s] || {}
  end

  def eyebrow(type)
    meta(type)["eyebrow"].to_s
  end

  # I18n-aware: tries card.badge.<type> in `locale` first, falling back to
  # the YAML's own English value — same shape as _card_component's eyebrow
  # lookup (t(..., default: CardTypes.eyebrow(type))). Defaults to the
  # ambient I18n.locale, which is the CREATOR's own platform language for
  # every call site today (all under switch_locale) — badge/panel_label are
  # dashboard chrome (results, the editor's deleted-cards list), never
  # rendered to a respondent, so they follow the viewer, not any Verto's
  # content locale.
  def badge(type, locale: I18n.locale)
    I18n.t("card.badge.#{type}", locale: locale, default: meta(type)["badge"].to_s)
  end

  # Same shape as badge above, for the picker-style caption shown above a
  # question in the results dashboard (application_helper#card_type_meta's
  # q_label).
  def panel_label(type, locale: I18n.locale)
    I18n.t("card.panel_label.#{type}", locale: locale, default: meta(type)["panel_label"].to_s)
  end

  def badge_css(type)
    meta(type)["badge_css"].to_s
  end

  # The brand hue that stands for this question type across the product.
  #
  # These are not new colours. The results screen has always painted each type's
  # card rail with a family gradient (see `left_bg_for` in
  # app/views/surveys/results.html.erb) — indigo for choice and scale, ocean for
  # binary and swipe, amber for ratings, magenta for open text — and the `.sb-*`
  # answer badges use the same families. `accent` is that family at chip
  # brightness, so an Ask Verto citation is painted the same hue the results page
  # already paints the question it cites.
  #
  # Every type must have one: a citation chip with no colour is a citation that
  # says less than the others, and CardTypesAccentTest fails the build rather
  # than let a new type ship colourless.
  ACCENT_FALLBACK = "#8B85FF".freeze

  def accent(type)
    meta(type)["accent"].presence || ACCENT_FALLBACK
  end

  # A soft wash of the type's accent, for tinted grounds. Kept here rather than
  # in CSS so Ruby and JS derive it identically.
  def accent_soft(type, alpha = 0.14)
    hex = accent(type).delete_prefix("#")
    r, g, b = hex.scan(/../).map { |pair| pair.to_i(16) }
    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  # The glyph the editor's type picker already uses. Reused on Ask Verto source
  # cards so a source is recognisable as "open text" or "rating" at a glance.
  def icon(type)
    meta(type)["picker_icon"].presence || "◆"
  end

  # Types gated behind a feature flag: hidden from the picker and the AI
  # generator unless their env flag is enabled. Lets the code ship dormant.
  FLAGGED = {}.freeze

  # Whether a card type is currently available. Non-flagged types are always on;
  # flagged types require their env flag (default off).
  def enabled?(type)
    env = FLAGGED[type.to_s]
    return true unless env
    ActiveModel::Type::Boolean.new.cast(ENV[env]) || false
  end

  # Types that should appear in the in-editor answer-type picker.
  def pickable
    DATA.select { |_key, attrs| attrs["pickable"] }
  end

  # Types withdrawn from the product (`retired: true` in the YAML).
  #
  # Retiring is not deleting, and the difference is the whole design. Answers
  # are keyed by card INDEX, and a Verto that has collected any is locked
  # against structural edits (Survey#editing_locked?) precisely so nothing can
  # renumber them. So a retired card is left exactly where it sits in a live
  # deck — pulling it out would shift every later answer already stored — and
  # is instead made inert: never offered (pickable: false), dropped from any
  # deck still editable (Survey.drop_retired_cards), skipped by the player
  # (player/show.html.erb) and refused as an answer (Survey#drop_retired_answers).
  # Its metadata stays so the results dashboard can still label what it
  # collected while it was live.
  def retired?(type)
    meta(type)["retired"] == true
  end

  # Card types with no answer captured — a "question" card is everything else.
  # welcome_card, token_checkpoint and points_intro are intro/milestone screens;
  # consent_gate captures an agreement and respondent_code a self-invented
  # identifier, both of which are recorded on the response itself
  # (consent_agreed_at, respondent_code_digest) rather than as an answer. None
  # are graded, scored, aggregated, or counted toward progress.
  NON_QUESTION_TYPES = %w[welcome_card token_checkpoint points_intro consent_gate respondent_code].freeze

  def question?(type)
    !NON_QUESTION_TYPES.include?(type.to_s)
  end

  # The picker list for one Verto: Points Checkpoint and Points Intro only
  # appear once tokenisation is on (they have nothing to show before then), and
  # Welcome disappears once the deck already has one — a second welcome card
  # greets the respondent twice, and the server drops it on save anyway
  # (Survey.enforce_single_welcome), so offering it is offering a card that
  # cannot survive.
  def pickable_for(survey)
    list = pickable
    list = list.reject { |key, _attrs| %w[token_checkpoint points_intro].include?(key) } unless survey&.tokenisation_enabled?
    # Types a deck may hold only one of. Survey.enforce_single_* drops the
    # second on save, so offering one is offering a card that cannot survive.
    %w[welcome_card respondent_code points_intro].each do |once|
      next unless survey && Array(survey.cards).any? { |c| c.is_a?(Hash) && c["type"].to_s == once }
      list = list.reject { |key, _attrs| key == once }
    end
    list
  end

  # JSON blob emitted into the editor page so the JS controller has the
  # same data without round-tripping the network. Keyed by type slug.
  def to_json
    DATA_BY_KEY.to_json
  end

  DATA = begin
    raw = YAML.load_file(Rails.root.join("config/card_types.yml"))
    raw.to_a # preserve YAML order
  end.freeze

  DATA_BY_KEY = DATA.to_h.freeze
end
