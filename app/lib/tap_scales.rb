# A tap card's RESPONSE SCALE — the answers a respondent chooses between on each
# swipe statement — loaded from config/tap_scales.yml.
#
# This is the single place the answer keys are written down. Before response sets
# were configurable the trio "yes" / "unsure" / "no" was spelled out literally in
# a dozen files (the aggregator's counts seed, the chart rows, the CSV export,
# the AI digests, both grading modules and their JS twins), and every one of them
# had to agree. They now all ask `keys_for` instead, so a new scale reaches the
# results page, the export and the token ledger without any of them being edited.
#
# A card opts into a scale by carrying a `responses` array; a card without one
# gets the historic 3-point scale, which is why every existing deck — including
# the partner imports in app/lib/verto_decks — keeps working untouched.
module TapScales
  module_function

  # The scale a card falls back to, and the one every deck predating this module
  # is implicitly on.
  DEFAULT_COUNT = 3

  # A creator may build any set between these. Two is the fewest that is still a
  # question; past six the strip stops fitting a phone card and the scale stops
  # being one a respondent can hold in their head.
  MIN_RESPONSES = 2
  MAX_RESPONSES = 6

  # From this many responses up, the strip stops being a row of labelled circles
  # in the scrim and fans out over the photo as text pills: five 48px circles do
  # not fit across a 320px card, and "Strongly disagree" is not a word a 22px
  # glyph can carry on its own.
  FAN_THRESHOLD = 5

  # Where a fanned response sits on the card, as percentages.
  #
  # The design lays the wide scales out on an ARC over the photo rather than in
  # a row: most-negative at the bottom left, the middle at the apex, most
  # positive at the bottom right. Measured off the design, the five pills sit at
  # 231°, 160°, 89°, 17° and -54° — evenly spaced around 285° of a slightly
  # squashed circle — which is the geometry below.
  #
  # It is not decoration. The arc is the same shape as the gesture: everything
  # left of the apex flies left, the apex flies up, everything right flies right,
  # so where an answer SITS is where the card goes when you pick it. A row can't
  # say that.
  # Symmetric about the apex (232 - 90 == 90 - -52), so the two extremes sit
  # exactly level and an odd scale's middle lands exactly on the centre line.
  FAN_START  = 232.0   # bottom left, the most negative answer
  FAN_END    = -52.0   # bottom right, the most positive
  FAN_CX     = 50.0
  FAN_CY     = 57.5
  FAN_RX     = 30.0
  FAN_RY     = 22.0

  # The historic three were translated as `card.swipe_*` long before this module
  # existed and are already carried in all 19 locale files. Preferring those keys
  # means an existing deck renders the same words in the same languages as it did
  # yesterday, whatever happens to the newer `card.tap_scale.*` strings.
  LEGACY_LABEL_KEYS = {
    "no" => "card.swipe_no", "unsure" => "card.swipe_unsure", "yes" => "card.swipe_yes"
  }.freeze

  KEY_FORMAT = /\A[a-z0-9_]{1,32}\z/

  # The built-in swipe glyphs a preset (or a creator) may name — the keys of
  # ApplicationHelper::TAP_RESPONSE_ICONS. Here rather than there so the model's
  # sanitiser can allowlist against it without reaching into a view helper;
  # tap_scales_test asserts the two lists stay in step.
  GLYPHS = %w[no unsure yes].freeze

  # Longest a response label may be ON SAVE. Deliberately NOT the 17 the editor
  # refuses to type past (verto_rules' SCALE_LABEL_MAX) — the two numbers are
  # answering different questions.
  #
  # 17 is what a column of the strip holds, and it is an authoring-time guard:
  # it stops a creator writing a label that won't fit, and never touches one
  # that already exists. This is the storage bound, and it has to clear every
  # label the app itself ships — 13 of the 19 locales translate an agreement
  # preset past 17 ("Zdecydowanie się nie zgadzam" is 28), so truncating here
  # would mangle a Polish or German Verto that nobody had even opened.
  #
  # Lower it to 17 and you do not tighten the cap; you corrupt the translations.
  MAX_LABEL = 40

  # The seed set for a count, or nil if that count has no preset. Dup'd, because
  # callers hand it to a creator to edit.
  def preset(count)
    entries = PRESETS[count.to_i]
    entries && entries.map(&:dup)
  end

  def preset_counts
    PRESETS.keys.sort
  end

  # The preset entry that defines a key, wherever it appears. Lets a card that
  # stores only {"key" => "neutral"} still render the right glyph and colour.
  def defaults_for_key(key)
    DEFAULTS_BY_KEY[key.to_s]
  end

  # Five and up fan out over the photo; four and under stay a row of circles in
  # the scrim, which is what the design shows and what the card has always done.
  def fan?(count)
    count.to_i >= FAN_THRESHOLD
  end

  # [x, y] percentages for one response on the fan. Evenly spaced along the arc,
  # first entry at FAN_START, last at FAN_END.
  def fan_position(index, count)
    count = count.to_i
    return [ FAN_CX, FAN_CY ] if count < 2

    degrees = FAN_START + ((FAN_END - FAN_START) / (count - 1)) * index
    radians = degrees * Math::PI / 180
    [ (FAN_CX + FAN_RX * Math.cos(radians)).round(2),
      (FAN_CY - FAN_RY * Math.sin(radians)).round(2) ]
  end

  # Which way the card flies when this response is chosen. The scale is ordered
  # most-negative first, so the left half exits left and the right half exits
  # right; the exact middle of an odd scale exits upward, which is what the
  # 3-point scale has always done with Unsure.
  def direction_for(index, count)
    middle = (count.to_i - 1) / 2.0
    return "up" if index == middle

    index < middle ? "left" : "right"
  end

  # The inverse, for the drag gesture: a fling can only express three intents, so
  # it commits the most extreme response on that side (and the middle one, on an
  # odd scale, for a fling upward). Tapping is how a respondent picks the ones in
  # between. Returns nil when the gesture has no answer to give — an upward fling
  # on an even scale — and the card snaps back.
  def index_for_direction(direction, count)
    count = count.to_i
    return nil if count < MIN_RESPONSES

    case direction.to_s
    when "left"  then 0
    when "right" then count - 1
    when "up"    then count.odd? ? (count - 1) / 2 : nil
    end
  end

  # This card's answer keys, in scale order. The one way anything downstream is
  # allowed to learn what a tap answer can say.
  def keys_for(card)
    stored = stored_responses(card)
    return stored.map { |r| r["key"].to_s } if stored

    PRESETS[DEFAULT_COUNT].map { |r| r["key"] }
  end

  def count_for(card)
    keys_for(card).size
  end

  # The resolved, ordered response set for rendering: preset defaults filled in
  # behind whatever the card stores, with the label resolved for `locale`.
  #
  # `locale` is the language the CARD is being shown in (the player's chosen one,
  # or the Verto's own), never the viewer's UI locale — a card must not mix
  # languages. Translated labels ride in card["i18n"][locale]["responses"],
  # aligned positionally exactly like `options`.
  def for_card(card, locale: nil, default_locale: nil)
    card    = {} unless card.is_a?(Hash)
    stored  = stored_responses(card)
    entries = stored || preset(DEFAULT_COUNT)
    count   = entries.size
    shown   = translated_labels(card, locale, default_locale)

    fan = fan?(count)

    entries.each_with_index.map do |entry, i|
      x, y = fan_position(i, count)
      key      = entry["key"].to_s
      fallback = DEFAULTS_BY_KEY[key] || {}
      # A STORED label is the creator's own words and always wins. A preset one
      # is not content yet — nobody has kept it — so it resolves through the
      # locale instead, or a card that has never been re-scaled would say "No"
      # in the middle of a French Verto.
      label = (stored && entry["label"].presence) || preset_label(key, fallback["label"], locale)
      {
        "key"       => key,
        "label"     => shown[i].presence || label,
        "canonical" => label,
        "icon"      => entry["icon"].presence,
        "emoji"     => entry["emoji"].presence || fallback["emoji"],
        "glyph"     => entry["glyph"].presence || fallback["glyph"],
        "color"     => entry["color"].presence || fallback["color"],
        "strong"    => entry.key?("strong") ? !!entry["strong"] : !!fallback["strong"],
        "index"     => i,
        "direction" => direction_for(i, count),
        "fan"       => fan,
        "x"         => x,
        "y"         => y
      }
    end
  end

  # Preset table for the editor, keyed by count. Mirrors CardTypes.to_json — the
  # JS builds a fresh response strip from the same data the server renders from.
  #
  # Labels are resolved in `locale`, which is the VERTO's language rather than
  # the viewer's, for the reason card_default_options_i18n gives: a preset label
  # is card content the moment the creator keeps it, so a French Verto must seed
  # "Plutôt d'accord", not "Agree".
  def to_json(locale = nil)
    { "presets" => presets_i18n(locale), "default_count" => DEFAULT_COUNT,
      "min" => MIN_RESPONSES, "max" => MAX_RESPONSES,
      "fan_threshold" => FAN_THRESHOLD }.to_json
  end

  def presets_i18n(locale = nil)
    PRESETS.transform_values do |entries|
      entries.map { |e| e.merge("label" => preset_label(e["key"], e["label"], locale)) }
    end
  end

  # ── internals ────────────────────────────────────────────────────────────────

  # The card's own set, or nil when it has none worth honouring. Deliberately
  # strict: a malformed or out-of-bounds array falls back to the 3-point scale
  # rather than rendering a card with one button or nine.
  def stored_responses(card)
    return nil unless card.is_a?(Hash)

    list = card["responses"]
    return nil unless list.is_a?(Array)

    valid = list.select { |r| r.is_a?(Hash) && r["key"].to_s.match?(KEY_FORMAT) }
    return nil unless valid.size.between?(MIN_RESPONSES, MAX_RESPONSES)
    return nil unless valid.size == list.size # a partly-broken set is not a set

    valid
  end

  def preset_label(key, english, locale)
    locale = locale.presence || I18n.locale
    if (legacy = LEGACY_LABEL_KEYS[key])
      return I18n.t(legacy, locale: locale, default: english || key)
    end

    I18n.t("card.tap_scale.#{key}", locale: locale, default: english || key)
  rescue I18n::InvalidLocale
    english || key
  end

  def translated_labels(card, locale, default_locale)
    default_locale = default_locale.presence || SupportedLocales::DEFAULT
    return [] if locale.blank? || locale.to_s == default_locale.to_s

    Array(card.dig("i18n", locale.to_s, "responses")).map(&:to_s)
  end

  PRESETS = begin
    raw = YAML.load_file(Rails.root.join("config/tap_scales.yml")).fetch("presets")
    raw.transform_keys(&:to_i).transform_values(&:freeze).freeze
  end

  # Every key any preset defines, so a card storing a bare key still resolves a
  # glyph and a colour. First definition wins; the presets agree on the ones they
  # share, and tap_scales_test asserts it.
  DEFAULTS_BY_KEY = PRESETS.values.flatten.each_with_object({}) { |entry, out|
    out[entry["key"]] ||= entry
  }.freeze
end
