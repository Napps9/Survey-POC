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
# range cards carry no still image (their left panel plays a reactive Lottie
# character) — instead they get a `range_theme` slug, seeded and theme-matched
# via NpsHelper.range_themes_for, so Shuffle re-rolls the animation the same
# way it re-rolls imagery.
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
  MOBILE_BG_DIR       = "verto-library/mobile-backgrounds".freeze

  TIER1_MIN_SCORE     = 5
  SELECT_TYPES        = %w[multiple_choice select_many select_one_grid select_many_grid yes_no prioritise].freeze
  SCALE_TYPES         = %w[range rating nps].freeze
  STOP_WORDS          = %w[
    the a an and or of for in on at to with from your our their this that
    do don't are is be how what when where why
  ].to_set.freeze

  # Filler specific to *question* text — interrogatives, second-person address,
  # auxiliaries and generic survey verbs — that name no visual subject. Removed
  # (on top of STOP_WORDS) when building the image-search query so what's left
  # is what the question is actually about ("which laptop brand would you
  # prefer?" → "laptop brand"), not the survey scaffolding around it.
  QUESTION_FILLER     = %w[
    which would could should will shall can may might must
    was were been being has have had does did done
    you your yours we our ours us they them their i me my mine
    like likes liked love loves want wants need needs prefer prefers
    think thinks feel feels choose chooses choosing select selecting pick picks
    rate rank tell describe say said please
    most least more less much many any some all none every each other else
    favourite favorite best worst good bad better
    often usually generally overall about really very just quite
    agree disagree
  ].to_set.freeze

  # ── Query hygiene (Pexels auto-population only) ───────────────────────────
  # Geography is CONTEXT, not the subject to depict: "schools in north London"
  # must search "school", never the place. Stripped from both theme and card
  # terms before a query is sent. (Editor manual search is untouched — the
  # creator types deliberately.)
  GEO_COMPASS = %w[
    north south east west northern southern eastern western
    northeast northwest southeast southwest central inner outer greater
  ].to_set.freeze

  # Geo nouns + a pragmatic net of major UK place names, so a lowercase theme
  # ("schools in north london") still loses the location. KNOWN v1 LIMITATION:
  # a lowercase MINOR place ("peckham") leaks through — same class of leak as
  # the original bug, far rarer; the relevance floor is the backstop.
  GEO_NOUNS = %w[
    city cities town towns village villages borough boroughs county counties
    district districts region regions area areas neighbourhood neighbourhoods
    suburb suburbs postcode council countryside local nearby
    uk britain british england english scotland scottish wales welsh
    ireland irish europe european
    london manchester birmingham leeds glasgow liverpool bristol sheffield
    edinburgh cardiff belfast newcastle nottingham
  ].to_set.freeze

  # Boilerplate in Pexels video-page slugs that must never contribute to a
  # relevance score.
  SLUG_NOISE = %w[https http www com pexels video videos photo photos].to_set.freeze

  # Card types with no depictable subject of their own — welcome/checkpoint
  # scaffolding. Their imagery is anchored to the Verto theme only; their own
  # copy (tone, not subject) is ignored. Mirrors CardTypes::NON_QUESTION_TYPES.
  SCAFFOLDING_TYPES = CardTypes::NON_QUESTION_TYPES.to_set.freeze

  # Relevance floors for an applied Pexels candidate (scored alt/slug against
  # the sent query, library-parity weights: +4 card subject, +3 theme term).
  CARD_RELEVANCE_FLOOR  = 4  # the photo must depict something the card names
  THEME_RELEVANCE_FLOOR = 3  # backgrounds / cards with no subject of their own

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

    # Picks a mobile card background URL for a survey by theme matching
    # against manifest.mobile_backgrounds. Used by the player view to
    # tint the card body on mobile with a brand-appropriate image
    # (rendered behind a white scrim so the question text stays readable).
    # Returns nil if no themed match exists — the white card body stays
    # plain in that case.
    def mobile_bg_url_for(survey)
      candidates = Array(manifest["mobile_backgrounds"])
      return nil if candidates.empty?

      query  = { themes: theme_keywords(survey.theme), age: age_buckets(survey.audience_age) }
      themed = candidates.select do |a|
        asset_themes = Array(a["themes"]).map { |t| t.to_s.downcase }
        (asset_themes & query[:themes]).any?
      end
      # No themed match? Fall back to a random pick from the whole pool so
      # the card body still gets a mobile background instead of going blank.
      pool = themed.presence || candidates

      # Stable per-survey choice; same Verto always lands on the same
      # picture so re-rendering doesn't flicker.
      chosen = pool[Random.new("mbg-#{survey.id}".hash).rand(pool.size)]
      ActionController::Base.helpers.asset_path("#{MOBILE_BG_DIR}/#{chosen['file']}")
    end

    # Helpers below mirror the instance-level versions so callers outside
    # the populator don't need an instance just to compute these.
    def theme_keywords(theme)
      raw = theme.to_s.downcase.scan(/[a-z]+/).reject { |w| STOP_WORDS.include?(w) }
      expand_themes(raw)
    end

    # Expand a list of theme keywords through manifest.theme_clusters so
    # conceptually-related themes pull each other in. A "food" survey
    # picks up `nature` / `sustainability` / `healthy` from the same
    # cluster, so a nature-themed background still scores for a food
    # Verto. Clusters are bidirectional.
    def expand_themes(themes)
      clusters = Array(manifest["theme_clusters"]).map { |c| Array(c).map { |s| s.to_s.downcase } }
      expanded = themes.dup
      clusters.each do |cluster|
        expanded.concat(cluster) if (themes & cluster).any?
      end
      expanded.uniq
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

    # Full list of swipe-card asset URLs (resolved through Sprockets so the
    # paths are fingerprinted). Used by the editor when a user adds a new
    # statement to a tap_card whose option_images were already populated —
    # the client picks an unused URL from this list.
    def swipe_card_urls
      helpers = ActionController::Base.helpers
      Array(manifest["swipe_cards"]).map do |a|
        helpers.asset_path("#{SWIPE_CARDS_DIR}/#{a['file']}")
      end
    end

    # Top-N curated assets for the picker's "Recommended" section, ranked by
    # the same scoring used by populate!. Empty array when nothing scores
    # above zero so the picker can hide the section instead of misleading.
    #
    #   recommended_paths(survey, context: :background)
    #   recommended_paths(survey, context: :card, card: cards_hash)
    def recommended_paths(survey, context:, card: nil, limit: 8)
      pop = new(survey)
      case context
      when :background then pop.send(:background_recommendations, limit)
      when :card       then pop.send(:card_recommendations, card, limit)
      else                  []
      end
    end
  end

  def initialize(survey, seed: nil)
    @survey = survey
    @seed   = seed || survey.id
    # Memoises Pexels search results per (query, orientation) so a populate!
    # run makes at most one API call per distinct query — keeps us well inside
    # the rate limit even for a long Verto.
    @pexels_cache       = {}
    @pexels_video_cache = {}
  end

  def populate!
    used       = Set.new   # left_panel + select_art + range_art picks
    swipe_used = Set.new   # swipe_cards picks across the whole survey

    @survey.background_image = safe_pick { pick_background_path }

    # Per-card rescue: one card's image pick failing (e.g. a transient Pexels
    # hiccup) must not abort the whole run and discard the background + every
    # other card's art. A failed card just keeps whatever it already had.
    #
    # media_idx counts cards that actually receive left-panel media, so we can
    # mix in video as a periodic accent: every 3rd such card prefers a video,
    # which (per the Rules of the Game variety principle) keeps videos from
    # ever sitting adjacent and caps photo runs at two — reducing fatigue.
    media_idx = 0
    cards = Array(@survey.cards).each_with_index.map do |card, idx|
      new_card = card.dup
      begin
        prefer_video = (media_idx % 3 == 2)
        if (picked = pick_card_image_path(card, idx, used, prefer_video: prefer_video))
          apply_card_media(new_card, picked)
          media_idx += 1
        end
        if card["type"].to_s == "tap_card"
          new_card["option_images"] = pick_tap_card_option_images(card, idx, swipe_used)
        end
        if card["type"].to_s == "range"
          new_card["range_theme"] = pick_range_theme(idx)
        end
      rescue => e
        Rails.logger.error("[AssetPopulator] card #{idx} (#{card['type']}): #{e.class}: #{e.message}")
      end
      new_card
    end

    @survey.cards = cards
    @survey.save!
  end

  # Run a pick that may reach Pexels; on any error log and return nil so the
  # caller falls back to "no image" rather than aborting populate!.
  def safe_pick
    yield
  rescue => e
    Rails.logger.error("[AssetPopulator] #{e.class}: #{e.message}")
    nil
  end

  # Apply a media pick hash onto a card. A card holds EITHER a photo (`image`)
  # OR a video (`video` + `video_poster`) in its left panel — set one and clear
  # the other so a re-populate/shuffle can switch a card between the two. The
  # credit fields are shared (the renderer labels them "Photo by"/"Video by").
  def apply_card_media(card, picked)
    if picked["video"].present?
      card["video"]        = picked["video"]
      card["video_poster"] = picked["video_poster"]
      card.delete("image")
    else
      card["image"] = picked["image"]
      card.delete("video")
      card.delete("video_poster")
    end

    if picked["image_credit"].present?
      card["image_credit"]     = picked["image_credit"]
      card["image_credit_url"] = picked["image_credit_url"]
    else
      card.delete("image_credit")
      card.delete("image_credit_url")
    end
  end

  private

  def pick_background_path
    # Pexels primary: a themed landscape backdrop. Falls back to the curated
    # backgrounds/ assets when Pexels is unconfigured or returns nothing.
    if (url = pexels_background_url)
      return url
    end

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

  # Picker for the card's left-panel image. Returns an asset_path/URL string or
  # nil (blank panel — same as Start-from-Blank).
  #
  # tap_card keeps its left panel blank — statement imagery rides on
  # option_images. For every other card type, Pexels (when configured) is the
  # primary source so coverage isn't limited to the themes the curated library
  # happens to hold; the curated two-tier logic is the fallback.
  #
  # Returns a media hash — a photo { "image", "image_credit", "image_credit_url" }
  # or a video { "video", "video_poster", "image_credit", "image_credit_url" } —
  # or nil. Only Pexels picks carry a credit. `prefer_video` asks for a video
  # first (used to mix media); it falls back to a photo when no video is found.
  def pick_card_image_path(card, idx, used, prefer_video: false)
    type = card["type"].to_s
    # tap_card's imagery rides on its statement cards; range shows the reactive
    # Lottie animation on its left panel — neither takes a left-panel still.
    return nil if type == "tap_card" || type == "range"

    if PexelsClient.configured?
      if prefer_video && (vid = pexels_card_video(card, idx, used))
        return vid
      end
      if (photo = pexels_card_photo(card, idx, used))
        url = PexelsClient.url_for(photo, :card)
        used << url
        return {
          "image"            => url,
          "image_credit"     => photo["photographer"].to_s.strip.presence,
          "image_credit_url" => photo["photographer_url"].to_s.strip.presence
        }
      end
    end

    if (path = tier1_themed_path(card, idx, used, type))
      used << path
      return { "image" => path }
    end

    if (path = tier2_type_art_path(card, idx, used, type))
      used << path
      return { "image" => path }
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
  # single card. Pool of 11 vs typical 5-8 statements means repeats rarely
  # bite, but we degrade gracefully if a survey has many tap_cards.
  def pick_tap_card_option_images(card, card_idx, swipe_used)
    options = Array(card["options"])
    return [] if options.empty?

    # Pexels primary: one themed landscape per statement. Falls back to the
    # curated swipe-cards/ pool when Pexels is unconfigured or returns nothing.
    if (urls = pexels_swipe_urls(card, card_idx, options.size, swipe_used))
      return urls
    end

    pool = Array(self.class.manifest["swipe_cards"])
    return [] if pool.empty?

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

  # The reaction-animation theme for a range card. Range cards carry no still
  # image — their left panel plays a Lottie character that reacts to the slider
  # — so this is their equivalent asset pick. Prefers an on-theme animation
  # (a Climate Verto reacts with recycling/flowers, not basketball), seeded so
  # the same seed is stable and Shuffle's new seed re-rolls it, exactly like
  # every image pick. Overwrites any prior pick as Shuffle does for imagery; the
  # creator can still re-choose from the card's Animation picker afterwards.
  def pick_range_theme(idx)
    pool = NpsHelper.range_themes_for(self.class.theme_keywords(@survey.theme))
    pool[rand_for("range-theme-#{idx}").rand(pool.size)]
  end

  # ── Pexels source ───────────────────────────────────────────────────────
  # All four picks above try Pexels first via these helpers; each returns nil
  # (or [] for swipe) so the curated fallback runs when Pexels is unconfigured
  # or a query comes back empty.

  # Memoised per (query, orientation): at most one API call per distinct query
  # for the whole populate! run.
  def pexels_photos(query, context)
    return [] unless PexelsClient.configured?
    orientation = PexelsClient::ORIENTATION_FOR[context]
    @pexels_cache[[ query, orientation ]] ||= begin
      results = PexelsClient.new.search(query: query, orientation: orientation, per_page: 30)
      fetched = results.size
      # 1. PG / age-appropriate for this Verto.
      results = results.select { |p| ContentSafety.safe?(p["alt"], safety_age_buckets) }
      safe = results.size
      # 2. Brand-neutral, unless the theme itself invokes the charged subject.
      results = results.select { |p| charged_theme? || ContentSafety.neutral?(p["alt"]) }
      Rails.logger.info("[AssetPopulator] pexels #{context} q=#{query.inspect} -> " \
                        "#{fetched} fetched / #{safe} safe / #{results.size} neutral")
      results
    end
  end

  def pexels_background_url
    query  = background_query
    photos = relevant(pexels_photos(query, :background), [], query_theme_words(query)) { |p| p["alt"] }
    return nil if photos.empty?
    chosen = photos[rand_for("bg").rand(photos.size)]
    PexelsClient.url_for(chosen, :background)
  end

  # The chosen Pexels photo for one card's left panel (so the caller can read
  # both its crop URL and photographer credit). Seeded order keeps same-seed
  # runs identical; the shared `used` set stops two cards landing on the same
  # photo (mirrors the curated de-dup).
  def pexels_card_photo(card, idx, used)
    query  = card_query(card)
    photos = relevant(pexels_photos(query, :card), card_relevance_words(card), query_theme_words(query)) { |p| p["alt"] }
    return nil if photos.empty?
    ordered = photos.shuffle(random: rand_for("px-#{idx}"))
    ordered.find { |p| !used.include?(PexelsClient.url_for(p, :card)) } || ordered.first
  end

  # A portrait video for one card's left panel, returned as a media hash. Picks
  # a small streamable mp4 + its poster, and the videographer credit. nil when
  # no usable video is found (caller falls back to a photo).
  def pexels_card_video(card, idx, used)
    query  = card_query(card)
    videos = relevant(pexels_videos(query), card_relevance_words(card), query_theme_words(query)) { |v| v["url"] }
    return nil if videos.empty?

    ordered = videos.shuffle(random: rand_for("pxv-#{idx}"))
    chosen  = ordered.find { |v| (u = PexelsClient.video_file_url(v)) && !used.include?(u) }
    url     = chosen && PexelsClient.video_file_url(chosen)
    return nil unless url

    used << url
    credit = PexelsClient.video_credit(chosen)
    {
      "video"            => url,
      "video_poster"     => PexelsClient.video_poster(chosen),
      "image_credit"     => credit["name"],
      "image_credit_url" => credit["url"]
    }
  end

  # Memoised portrait video search (one API call per distinct query per run).
  def pexels_videos(query)
    return [] unless PexelsClient.configured?
    @pexels_video_cache[query] ||= begin
      results = PexelsClient.new.search_videos(query: query, orientation: "portrait", per_page: 15)
      # Videos carry no alt text; the page-URL slug is the best signal we have.
      results = results.select { |v| ContentSafety.safe?(v["url"], safety_age_buckets) }
      results = results.select { |v| charged_theme? || ContentSafety.neutral?(v["url"]) }
      Rails.logger.info("[AssetPopulator] pexels video q=#{query.inspect} -> #{results.size} result(s)")
      results
    end
  end

  # One landscape per tap_card statement, unique within the card and preferring
  # photos not used by another tap_card. Returns nil to trigger the fallback.
  def pexels_swipe_urls(card, card_idx, count, swipe_used)
    return nil unless PexelsClient.configured?
    query  = card_query(card)
    photos = relevant(pexels_photos(query, :swipe), card_relevance_words(card), query_theme_words(query)) { |p| p["alt"] }
    urls   = photos.map { |p| PexelsClient.url_for(p, :swipe) }.compact.uniq
    return nil if urls.empty?

    rng = rand_for("pxtap-#{card_idx}")
    fresh, used_elsewhere = urls.partition { |u| !swipe_used.include?(u) }
    ordered = fresh.shuffle(random: rng) + used_elsewhere.shuffle(random: rng)
    ordered *= ((count.to_f / ordered.size).ceil) if ordered.size < count

    picks = ordered.first(count)
    picks.each { |u| swipe_used << u }
    picks
  end

  # Search-query builders reuse the same theme/keyword signals the curated
  # scorer uses, so Pexels picks track the survey the same way.
  def theme_query_terms
    @survey.theme.to_s.downcase.scan(/[a-z]+/).reject { |w| STOP_WORDS.include?(w) }
  end

  # Does this Verto's theme deliberately invoke the protest/activism topic?
  # When it does, the neutrality suppression and charged-term query stripping
  # switch off for the whole run — the creator's stated topic wins. Memoised.
  def charged_theme?
    return @charged_theme if defined?(@charged_theme)
    @charged_theme = ContentSafety.charged_theme?(@survey.theme)
  end

  # Downcased tokens judged to be proper nouns in the ORIGINAL text — run
  # BEFORE downcasing destroys the signal. A capitalised token that is NOT the
  # first word of its sentence is a place/brand/name; ALL-CAPS acronyms count
  # anywhere. Applied to CARD copy only (question/description), never the theme
  # (themes are routinely title-cased, so mid-caps carry no signal there).
  def proper_nouns(text)
    names = Set.new
    text.to_s.split(/[.?!:]+/).each do |sentence|
      sentence.scan(/[A-Za-z][A-Za-z']*/).each_with_index do |tok, i|
        names << tok.downcase if tok.match?(/\A[A-Z]{2,}\z/)
        names << tok.downcase if i.positive? && tok.match?(/\A[A-Z][a-z]/)
      end
    end
    names
  end

  # Terms fit to send to Pexels: no geography, no proper nouns, no charged
  # terms (unless the theme itself invokes them). Query = SUBJECT, not CONTEXT.
  def subject_terms(tokens, names = Set.new)
    tokens.reject do |w|
      GEO_COMPASS.include?(w) || GEO_NOUNS.include?(w) || names.include?(w) ||
        (!charged_theme? && ContentSafety::CHARGED.include?(w))
    end
  end

  # The theme's depictable subject terms — geography and charged words removed.
  # The shared base for every card's query (background and cards alike).
  def clean_theme_terms
    @clean_theme_terms ||= subject_terms(theme_query_terms)
  end

  # Age buckets for the Verto's audience, driving the content-safety blocklist
  # (kids/teen get the stricter list). Memoised for the run.
  def safety_age_buckets
    @safety_age_buckets ||= self.class.age_buckets(@survey.audience_age)
  end

  def background_query
    # Backgrounds KEEP geography — a full-bleed skyline/landscape for the
    # Verto's place is neutral and legitimate (a "London life" Verto's
    # backdrop should be able to be London). Only charged terms are stripped
    # (unless the theme invokes them). The screenshot confirmed the theme-only
    # background was already correct; the bug was card copy, not the backdrop.
    terms = theme_query_terms.reject { |w| !charged_theme? && ContentSafety::CHARGED.include?(w) }
    raw   = terms.first(3).join(" ").presence || "abstract background"
    ContentSafety.scrub_query(raw, safety_age_buckets).presence || "abstract background"
  end

  # Theme-anchored: the BASE of every card query is the Verto theme's subject,
  # so a card's own copy can never drag the search off-topic (the real bug —
  # a welcome card's "your voice matters…" landing on protest stock).
  #
  # Scaffolding cards (welcome/checkpoint) have no subject of their own — they
  # are theme-only, no per-word analysis. Ordinary question cards may REFINE
  # the theme base with their own concrete terms, but only ones that survive
  # the hygiene strips (geo, proper nouns, charged) — fail-closed: an unknown
  # word is simply not added, never allowed to steer the query on its own.
  # TODO(phase two): a real concrete-noun / depictable-subject extractor so a
  # card like "How was the school canteen?" contributes "canteen".
  def card_query(card)
    base = clean_theme_terms.first(2)
    refine =
      if theme_only_card?(card)
        []
      else
        subject_terms(card_keywords(card), proper_nouns("#{card['text']} #{card['description']}"))
      end
    terms = (base + refine).uniq { |w| w.singularize }
    raw   = terms.join(" ").presence || clean_theme_terms.first(3).join(" ").presence || "abstract"
    ContentSafety.scrub_query(raw, safety_age_buckets).presence || "abstract"
  end

  # Cards imaged from the Verto theme ONLY, ignoring their own copy: scaffolding
  # (welcome/checkpoint) which have no subject, AND the demographic form fields
  # (Gender/birth/location) whose copy names a sensitive subject that must not
  # steer a stock-photo search (the "Gender" card pulling identity/edgy imagery).
  def theme_only_card?(card)
    SCAFFOLDING_TYPES.include?(card["type"].to_s) || card["demographic"].present?
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
      themes: self.class.theme_keywords(@survey.theme),
      age:    self.class.age_buckets(@survey.audience_age),
      mood:   %w[playful energetic festive warm calm],
      style:  []
    }
  end

  # theme_keywords / age_buckets are class methods now (see top of file);
  # the instance code calls self.class so there's one source of truth.

  # Salient words from a card, question-first: the question text leads (it
  # names the subject), then description and options fill in behind it. Filler
  # (STOP_WORDS + QUESTION_FILLER) and tokens under three letters are dropped,
  # so what survives is what the card is visually about. De-duped, first
  # occurrence wins — which is why the query's first(3) keeps the question's
  # own subject ahead of words that only appear among the options.
  def card_keywords(card)
    question = salient_words(card["text"])
    rest     = salient_words([ card["description"], *Array(card["options"]) ].compact.join(" "))
    (question + rest).uniq
  end

  def salient_words(text)
    text.to_s.downcase.scan(/[a-z]+/).reject do |w|
      w.length < 3 || STOP_WORDS.include?(w) || QUESTION_FILLER.include?(w)
    end
  end

  # ── Pexels relevance floor ────────────────────────────────────────────────
  # An uncurated source needs MORE scrutiny than the curated library, not less:
  # a returned photo is only applied if its alt (or a video's page slug) shares
  # real subject vocabulary with the card and theme. Function words can never
  # score (salient_words drops STOP_WORDS + QUESTION_FILLER), and singularize
  # matches "schools" to "school".
  def relevance_tokens(text)
    (salient_words(text) - SLUG_NOISE.to_a).map(&:singularize).uniq
  end

  # Library-parity weights: +4 per card-subject hit, +3 per theme-term hit.
  def relevance_score(text, card_words, theme_words)
    tokens = relevance_tokens(text)
    4 * (tokens & card_words).size + 3 * (tokens & theme_words).size
  end

  # The card's own subject words for scoring — empty for theme-only cards
  # (scaffolding + demographic form fields), so they fall to the theme floor
  # rather than scoring a candidate on their own tone/sensitive terms.
  def card_relevance_words(card)
    return [] if theme_only_card?(card)
    relevance_tokens("#{card['text']} #{card['description']} #{Array(card['options']).join(' ')}")
  end

  # Filter Pexels candidates to those clearing the relevance floor. Floor is
  # per-context: a card with subject words must be depicted (4); a background
  # or a scaffolding card is measured on theme terms only (3). Only when BOTH
  # word-sets are empty (nothing to measure) is the floor bypassed — so a bare
  # welcome card on a real theme is still theme-floor protected.
  def relevant(items, card_words, theme_words, &text_for)
    return items if card_words.empty? && theme_words.empty?
    floor = card_words.any? ? CARD_RELEVANCE_FLOOR : THEME_RELEVANCE_FLOOR
    items.select { |it| relevance_score(text_for.call(it), card_words, theme_words) >= floor }
  end

  # Theme-side scoring words = tokens of the query actually SENT (not the raw
  # theme), so a place-only "London life" background — whose query keeps
  # "london" — can be matched by a "London skyline" alt.
  def query_theme_words(query)
    relevance_tokens(query)
  end

  def rand_for(slot)
    Random.new("#{@seed}-#{slot}".hash)
  end

  def helpers
    @helpers ||= ActionController::Base.helpers
  end

  # Top-N background asset_paths for the picker's "Recommended" section.
  def background_recommendations(limit)
    rank_pool(self.class.manifest["backgrounds"], BACKGROUND_DIR, survey_query_tags, limit)
  end

  # Top-N card asset_paths blending theme-matched left-panel art and the
  # card-type-family pool (select/range/swipe), so both Tier-1 themed picks
  # and Tier-2 type-fit picks show up in one ranked list.
  def card_recommendations(card, limit)
    return [] if card.blank?
    type  = card["type"].to_s
    query = survey_query_tags.merge(keywords: card_keywords(card))

    scored = []
    Array(self.class.manifest["left_panel"]).each do |a|
      types = Array(a["card_types"])
      next unless types.empty? || types.include?(type)
      scored << [ score(a, query), asset_url(LEFT_PANEL_DIR, a["file"]) ]
    end

    family_bucket, family_dir = type_family_pool(type)
    Array(family_bucket).each do |a|
      scored << [ score(a, query), asset_url(family_dir, a["file"]) ]
    end

    scored.reject! { |s, _| s <= 0 }
    scored.sort_by! { |s, _| -s }
    scored.first(limit).map(&:last)
  end

  def type_family_pool(type)
    if SELECT_TYPES.include?(type) then [ self.class.manifest["select_art"],  SELECT_ART_DIR ]
    elsif SCALE_TYPES.include?(type) then [ self.class.manifest["range_art"], RANGE_ART_DIR ]
    elsif type == "tap_card"        then [ self.class.manifest["swipe_cards"], SWIPE_CARDS_DIR ]
    else [ nil, nil ]
    end
  end

  def rank_pool(pool, dir, query, limit)
    scored = Array(pool).map { |a| [ score(a, query), asset_url(dir, a["file"]) ] }
    scored.reject! { |s, _| s <= 0 }
    scored.sort_by! { |s, _| -s }
    scored.first(limit).map(&:last)
  end
end
