# Pre-populates a Verto's `background_image`, each card's left-panel `image`,
# and (for tap_card cards) each statement's `option_images` from the curated
# verto-library, using a two-tier hierarchy for the left-panel image:
#
#   Tier 1 — Themed match from manifest.left_panel that scores above
#            TIER1_MIN_SCORE against the survey's theme + audience and the
#            card's text + options.
#   Tier 2 — Card-type-family art (select_art for the select/grid family,
#            range_art for range/rating/nps). NOT used for tap_card: those
#            get their imagery on the statement cards themselves via
#            `option_images`, not on the left panel.
#   (No SVG fallback — leave the card image blank rather than reach into
#    the design-system SVGs at app/assets/images/.)
#
# tap_card statement imagery: every tap_card gets a parallel `option_images`
# array drawn from manifest.swipe_cards, one image per entry in `options`,
# no repeats within a card and preferring assets not already used elsewhere
# in the survey.
#
# Background uses manifest.backgrounds with the same scoring. If every entry
# scores zero the seed selects one round-robin so the editor never opens
# with a blank backdrop.
#
# Shuffle: pass a different `seed:` and call populate! again.
class AssetPopulator
  MANIFEST_PATH       = Rails.root.join("app/assets/images/verto-library/manifest.yml").freeze
  BACKGROUND_DIR      = "verto-library/backgrounds".freeze
  LEFT_PANEL_DIR      = "verto-library/left-panel".freeze
  SELECT_ART_DIR      = "verto-library/select-art".freeze
  RANGE_ART_DIR       = "verto-library/range-art".freeze
  SWIPE_CARDS_DIR     = "verto-library/swipe-cards".freeze

  TIER1_MIN_SCORE     = 5
  SELECT_TYPES        = %w[multiple_choice select_many select_one_grid select_many_grid yes_no].freeze
  SCALE_TYPES         = %w[range rating nps].freeze
  STOP_WORDS          = %w[
    the a an and or of for in on at to with from your our their this that
    do don't are is be how what when where why
  ].to_set.freeze

  class << self
    def manifest
      @manifest_mtime ||= nil
      mtime = File.mtime(MANIFEST_PATH) rescue nil
      if @manifest.nil? || @manifest_mtime != mtime
        @manifest = MANIFEST_PATH.exist? ? YAML.safe_load(MANIFEST_PATH.read, permitted_classes: [ Symbol ]) || {} : {}
        @manifest_mtime = mtime
      end
      @manifest
    end

    def reset_manifest_cache!
      @manifest      = nil
      @manifest_mtime = nil
    end
  end

  def initialize(survey, seed: nil)
    @survey = survey
    @seed   = seed || survey.id
  end

  def populate!
    used       = Set.new   # left_panel + select_art + range_art picks
    swipe_used = Set.new   # swipe_cards picks across the whole survey

    @survey.background_image = pick_background_path

    cards = Array(@survey.cards).each_with_index.map do |card, idx|
      new_card = card.dup
      if (img = pick_card_image_path(card, idx, used))
        new_card["image"] = img
      end
      if card["type"].to_s == "tap_card"
        new_card["option_images"] = pick_tap_card_option_images(card, idx, swipe_used)
      end
      new_card
    end

    @survey.cards = cards
    @survey.save!
  end

  private

  def pick_background_path
    candidates = Array(self.class.manifest["backgrounds"])
    return nil if candidates.empty?

    query  = survey_query_tags
    # Prefer theme-matching backgrounds. Without this filter the age/mood
    # bonuses on sport.jpg ([teen, young-adult] + [playful, energetic])
    # eclipse a clean theme hit on nature.jpg for a Climate Verto.
    themed = candidates.select { |a| theme_match?(a, query) }
    pool   = themed.presence || candidates

    scored = pool.map { |a| [ score(a, query), a ] }
    top    = scored.max_by { |s, _| s }
    chosen =
      if top && top[0] > 0
        top[1]
      else
        pool[rand_for("bg").rand(pool.size)]
      end
    helpers.asset_path("#{BACKGROUND_DIR}/#{chosen['file']}")
  end

  # Two-tier picker for the card's left-panel image. Returns an
  # asset_path string or nil (blank panel — same as Start-from-Blank).
  def pick_card_image_path(card, idx, used)
    type = card["type"].to_s

    if (path = tier1_themed_path(card, idx, used, type))
      used << path
      return path
    end

    if (path = tier2_type_art_path(card, idx, used, type))
      used << path
      return path
    end

    nil
  end

  def tier1_themed_path(card, idx, used, type)
    query = survey_query_tags.merge(keywords: card_keywords(card))

    # Require BOTH a card-type fit AND a thematic connection (theme keyword
    # OR card-keyword overlap). Without the theme/keyword gate, sports-people
    # art would happily land on a Climate Verto purely on age/mood scoring.
    type_matching = Array(self.class.manifest["left_panel"]).select do |a|
      types = Array(a["card_types"])
      (types.empty? || types.include?(type)) && theme_match?(a, query)
    end
    return nil if type_matching.empty?

    # Prefer unused assets but allow repeats once the type-matching pool
    # is exhausted — better to repeat a themed image than leave it blank.
    unused = type_matching.reject { |a| used.include?(asset_url(LEFT_PANEL_DIR, a["file"])) }
    pool   = unused.presence || type_matching

    scored = pool.map { |a| [ score(a, query), a ] }
                 .select { |s, _| s >= TIER1_MIN_SCORE }
    return nil if scored.empty?

    best   = scored.map(&:first).max
    top    = scored.select { |s, _| s == best }.map(&:last)
    chosen = top[rand_for("t1-#{idx}").rand(top.size)]
    asset_url(LEFT_PANEL_DIR, chosen["file"])
  end

  def tier2_type_art_path(_card, idx, used, type)
    bucket, dir =
      if SELECT_TYPES.include?(type)
        [ self.class.manifest["select_art"], SELECT_ART_DIR ]
      elsif SCALE_TYPES.include?(type)
        [ self.class.manifest["range_art"], RANGE_ART_DIR ]
      end
    # tap_card deliberately omitted: swipe-cards/ assets are for the
    # statement cards themselves (populated via option_images), not the
    # tap_card's left panel.
    return nil if bucket.nil?

    pool = Array(bucket)
    return nil if pool.empty?

    available = pool.reject { |a| used.include?(asset_url(dir, a["file"])) }
    available = pool if available.empty?  # pool exhausted — repeats OK

    chosen = available[rand_for("t2-#{idx}").rand(available.size)]
    asset_url(dir, chosen["file"])
  end

  # Picks one image per option for a tap_card, drawn from manifest.swipe_cards.
  # Prefers assets not yet used elsewhere in the survey; no repeats within a
  # single card. Pool of 11 vs typical 3-5 statements means repeats rarely
  # bite, but we degrade gracefully if a survey has many tap_cards.
  def pick_tap_card_option_images(card, card_idx, swipe_used)
    options = Array(card["options"])
    pool    = Array(self.class.manifest["swipe_cards"])
    return [] if options.empty? || pool.empty?

    rng = rand_for("tap-#{card_idx}")

    unused, used_elsewhere = pool.partition do |a|
      !swipe_used.include?(asset_url(SWIPE_CARDS_DIR, a["file"]))
    end
    ordered = unused.shuffle(random: rng) + used_elsewhere.shuffle(random: rng)
    # Pool smaller than options? cycle until we have enough.
    ordered *= ((options.size.to_f / ordered.size).ceil) if ordered.size < options.size

    picks = ordered.first(options.size)
    urls  = picks.map { |a| asset_url(SWIPE_CARDS_DIR, a["file"]) }
    urls.each { |u| swipe_used << u }
    urls
  end

  def asset_url(dir, file)
    helpers.asset_path("#{dir}/#{file}")
  end

  # True when an asset has at least one theme keyword or card keyword in
  # common with the query — i.e. there's a real thematic connection rather
  # than an accidental age/mood/style overlap. Used to gate Tier-1 and the
  # background picker so off-theme assets aren't picked on bonuses alone.
  def theme_match?(asset, query)
    asset_themes   = Array(asset["themes"]).map { |t| t.to_s.downcase }
    asset_keywords = Array(asset["keywords"]).map { |k| k.to_s.downcase }
    (asset_themes & Array(query[:themes]).to_a).any? ||
      (asset_keywords & Array(query[:keywords]).to_a).any?
  end

  # Score one manifest asset against a query hash.
  #   +3 per matching theme keyword
  #   +2 per matching age bucket (or +1 if asset is `all`)
  #   +2 per matching mood
  #   +1 per matching style
  #   +4 per asset keyword found in card text+options
  def score(asset, query)
    s = 0
    asset_themes = Array(asset["themes"]).map { |t| t.to_s.downcase }
    s += 3 * (asset_themes & query[:themes].to_a).size

    asset_ages = Array(asset["age"]).map { |a| a.to_s.downcase }
    if asset_ages.include?("all")
      s += 1
    else
      s += 2 * (asset_ages & query[:age].to_a).size
    end

    asset_moods = Array(asset["mood"]).map { |m| m.to_s.downcase }
    s += 2 * (asset_moods & query[:mood].to_a).size

    asset_styles = Array(asset["style"]).map { |st| st.to_s.downcase }
    s += 1 * (asset_styles & query[:style].to_a).size

    if query[:keywords]
      kws = Array(asset["keywords"]).map { |k| k.to_s.downcase }
      s += 4 * (kws & query[:keywords].to_a).size
    end

    s
  end

  def survey_query_tags
    {
      themes: theme_keywords(@survey.theme),
      age:    age_buckets(@survey.audience_age),
      mood:   %w[playful energetic festive warm calm],
      style:  []
    }
  end

  def theme_keywords(theme)
    theme.to_s.downcase.scan(/[a-z]+/).reject { |w| STOP_WORDS.include?(w) }
  end

  def age_buckets(audience_age)
    s = audience_age.to_s.downcase
    buckets = []
    buckets << "kids"        if s.match?(/\bkids?\b|\bchildren\b|\b(?:5|6|7|8|9|10|11)\b|primary[- ]school/)
    buckets << "teen"        if s.match?(/\bteen|\b1[2-7]\b|high[- ]school|secondary[- ]school/)
    buckets << "young-adult" if s.match?(/\b(?:18|19|20|21|22|23|24)\b|18.?24|18.?29|young|university|student|gen ?z/)
    buckets << "adult"       if s.match?(/\b(?:25|26|27|28|29|30|31|32|33|34|35|36|37|38|39|40|41|42|43|44|45|46|47|48|49|50|51|52|53|54)\b|25.?34|35.?44|45.?54|adults?|parents?|professionals?|workers?/)
    buckets << "senior"      if s.match?(/\b(?:55|56|57|58|59|60|65|70|75|80)\b|55\+|seniors?|elderly|retired/)
    buckets.empty? ? [ "all" ] : buckets
  end

  def card_keywords(card)
    text = [
      card["text"],
      card["description"],
      *Array(card["options"])
    ].compact.join(" ").downcase
    text.scan(/[a-z]+/).reject { |w| STOP_WORDS.include?(w) }
  end

  def rand_for(slot)
    Random.new("#{@seed}-#{slot}".hash)
  end

  def helpers
    @helpers ||= ActionController::Base.helpers
  end
end
