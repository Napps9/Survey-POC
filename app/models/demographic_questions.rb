# Every Verto ends with the same three set demographic questions, appended
# automatically at creation (generate, PDF import). They give every Verto a
# comparable demographic tail — birth year, location, gender — powering the
# research collective across the platform. Cards carry "demographic" => true
# so they're identifiable downstream and never appended twice.
module DemographicQuestions
  CARDS = [
    { "type" => "open_ended", "input" => "month", "text" => "When were you born?",
      "demographic" => true },
    { "type" => "open_ended", "input" => "location", "text" => "Where do you live?",
      "description" => "Powered by OpenStreetMap — helps build a map you can explore after finishing.",
      "demographic" => true },
    { "type" => "multiple_choice", "text" => "Gender",
      "options" => [ "Male", "Female", "Non-binary", "Other", "Prefer not to say" ],
      "demographic" => true }
  ].freeze

  # The three cards resolved in `locale` (a Verto's default_locale), falling
  # back to the English above. Every Verto used to get the English tail
  # regardless of its language — a French generated Verto ended with "Where do
  # you live?". Translations live under `demographics.cards` in the locale
  # files, merged positionally; an options list is only taken whole and at the
  # registry length, because answers are positional.
  def self.cards(locale: nil)
    translated = Array(I18n.t("demographics.cards", locale: locale.presence || I18n.locale, default: nil))
    CARDS.each_with_index.map do |card, i|
      c = card.dup
      tr = translated[i]
      next c unless tr.is_a?(Hash)
      tr = tr.transform_keys(&:to_s)
      c["text"]        = tr["text"].to_s        if tr["text"].to_s.strip.present?
      c["description"] = tr["description"].to_s if tr["description"].to_s.strip.present?
      opts = tr["options"]
      c["options"] = opts.map(&:to_s) if opts.is_a?(Array) && opts.size == Array(c["options"]).size
      c
    end
  rescue I18n::InvalidLocale
    CARDS.map(&:dup)
  end

  def self.append_to(cards, locale: nil)
    list = Array(cards)
    return list if list.any? { |c| c.is_a?(Hash) && c["demographic"] }
    list + cards(locale: locale)
  end

  # ── Opt-in demographic questions ───────────────────────────────────────────
  # Unlike CARDS, never auto-appended: a creator adds these per-Verto from the
  # add-question modal's Demographics tiles. Keyed by `demographic_key` — the
  # discriminator the answer sync (PlayerController#sync_demographics_from_answers!)
  # and results segmentation slice on, and the reason two multiple-choice
  # demographic cards can coexist with the Gender tail card (which has no key).
  OPTIONAL_CARDS = {
    "heritage" => {
      "type" => "multiple_choice",
      "text" => "Which of these best reflects your heritage?",
      "description" => "Your ethnic or cultural background.",
      "options" => [ "Asian heritage", "Black, African or Caribbean heritage",
                     "Hispanic or Latino/a", "Middle Eastern or North African heritage",
                     "White or European heritage", "Indigenous heritage",
                     "Mixed or multiple heritage", "Another heritage", "Prefer not to say" ],
      "demographic" => true, "demographic_key" => "heritage"
    },
    # Deliberately framed around how people think and process information —
    # many neurodivergent respondents don't describe themselves as disabled or
    # having a disability, and a disability-framed question would undercount
    # exactly the people it is trying to understand.
    "neurodiversity" => {
      "type" => "select_many",
      "text" => "Do any of these describe you?",
      "description" => "About how you think and process information — choose any that apply.",
      "options" => [ "ADHD", "Autism", "Dyslexia", "Dyspraxia", "Dyscalculia",
                     "Tourette's", "Another form of neurodivergence",
                     "None of these", "Prefer not to say" ],
      "demographic" => true, "demographic_key" => "neurodiversity"
    }
  }.freeze

  # Every key Survey.sanitize_cards_images! will accept. "gender" is reserved
  # so a future migration can tag the legacy tail card without another
  # allowlist change.
  DEMOGRAPHIC_KEYS = (OPTIONAL_CARDS.keys + [ "gender" ]).freeze

  # One optional card resolved in `locale`, or nil for an unknown key. Deep
  # dup (options array included) — callers mutate the hash (cid stamping,
  # i18n prefill). Same translation posture as `cards`: text/description only
  # when present, options only whole and at registry length, English on an
  # invalid locale.
  def self.optional_card(key, locale: nil)
    spec = OPTIONAL_CARDS[key.to_s]
    return nil unless spec

    card = spec.dup
    card["options"] = spec["options"].dup
    tr = I18n.t("demographics.optional.#{key}", locale: locale.presence || I18n.locale, default: nil)
    return card unless tr.is_a?(Hash)

    tr = tr.transform_keys(&:to_s)
    card["text"]        = tr["text"].to_s        if tr["text"].to_s.strip.present?
    card["description"] = tr["description"].to_s if tr["description"].to_s.strip.present?
    opts = tr["options"]
    card["options"] = opts.map(&:to_s) if opts.is_a?(Array) && opts.size == spec["options"].size
    card
  rescue I18n::InvalidLocale
    card
  end

  # The heritage card's last two options ("Another heritage", "Prefer not to
  # say") in `locale` — the escape hatches that survive when the seven
  # country-specific categories replace the global taxonomy. Identified
  # positionally as the LAST TWO registry options, the same convention
  # neuro_exclusive_labels uses, so a locale that translated the list whole
  # gets its own wording and one that didn't falls back to English.
  def self.heritage_tail_options(locale: nil)
    Array(optional_card("heritage", locale: locale)["options"]).last(2)
  end

  # The heritage card with `five` country-specific categories in place of the
  # global nine, keeping the registry's tail pair below them — so the card asks
  # about Kenyan or Brazilian heritage while a respondent who fits none of it,
  # or would rather not say, still has somewhere to go.
  #
  # Pure: `five` arrives already generated and sanitised (HeritageOptions), so
  # nothing here calls a service or can fail. A blank list returns the plain
  # registry card, which is what makes "Claude was unreachable" degrade to the
  # global taxonomy rather than to an error.
  #
  # `allow_other` rides along because a five-item list WILL miss people: the
  # free-text box is the difference between a respondent seeing themselves as
  # "Another heritage" and being able to say what they actually are.
  def self.country_heritage_card(country:, five:, locale: nil)
    card = optional_card("heritage", locale: locale)
    return card if card.nil? || Array(five).empty?

    code = country.to_s.upcase
    return card unless WorldRegions.valid?(code)

    card["options"]          = Array(five).map(&:to_s) + heritage_tail_options(locale: locale)
    card["allow_other"]      = true
    card["heritage_country"] = code
    card
  end

  # The neurodiversity card's two mutually-exclusive options ("None of these",
  # "Prefer not to say") in EVERY available locale. Stored answers are
  # canonical primary-language labels, so a French Verto stores the French
  # pair — the sync's exclusivity rule has to recognise them all. Identified
  # positionally as the LAST TWO registry options, mirroring optional_card's
  # whole-list-only translation guard.
  def self.neuro_exclusive_labels
    @neuro_exclusive_labels ||= begin
      size = OPTIONAL_CARDS["neurodiversity"]["options"].size
      labels = OPTIONAL_CARDS["neurodiversity"]["options"].last(2)
      I18n.available_locales.each do |loc|
        opts = I18n.t("demographics.optional.neurodiversity.options", locale: loc, default: nil)
        labels += opts.last(2).map(&:to_s) if opts.is_a?(Array) && opts.size == size
      end
      labels.to_set.freeze
    end
  end
end
