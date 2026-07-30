class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy
  has_many :partnership_vertos, dependent: :destroy
  has_many :report_renders, dependent: :destroy

  # Creator-uploaded card/background imagery. Previously these lived inline in
  # the `cards` JSON as base64 data-URLs, which meant every render of a Verto
  # re-materialized several MB of image data into memory — the acknowledged
  # driver behind the production 502s on a 512MB instance (P1-7). Now the bytes
  # live in Active Storage (a persistent Render disk) and the cards JSON keeps
  # only a short /rails/active_storage/... path.
  #
  # Attached to the Verto, not the organisation, so they purge with it and stay
  # out of the account's curated brand-asset library (Organisation#assets).
  has_many_attached :card_images

  CARD_IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
  # Matches the client-side downscale budget (1600px longest edge, WebP q0.82);
  # generous enough for an image that skipped downscaling, small enough that a
  # deck can't fill the disk.
  CARD_IMAGE_MAX_BYTES = 3.megabytes

  scope :recent,   -> { order(updated_at: :desc) }
  scope :kept,     -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

  # Range cards are always a 5-point scale (see RANGE_POINTS). Enforced on the
  # way in so every authoring path is covered by one rule, and skipped once a
  # Verto is live: a stored answer is an INDEX into the scale it was collected
  # on, so resizing a published card's options would silently re-point every
  # response already gathered. Published Vertos are locked for editing anyway.
  before_save :enforce_range_scale, if: -> { will_save_change_to_cards? && !published? }

  # Large AI-generated TEXT columns only needed on the results path. Omit them
  # everywhere else (editor, dashboard, player, preview) so multi-KB blobs
  # aren't loaded into every row for nothing — a pure baseline memory saving.
  # A record loaded this way must not write these columns (they're absent);
  # the results path and surveys#update load the full row.
  HEAVY_REPORT_COLUMNS = %w[results_summary results_report].freeze
  scope :without_report_text, -> { select(column_names - HEAVY_REPORT_COLUMNS) }

  def deleted?
    deleted_at.present?
  end

  # Languages this Verto exists in, primary (default_locale) first. Legacy
  # Vertos with no `locales` set fall back to just their primary language.
  def verto_locales
    ([ default_locale ] + SupportedLocales.sanitize_list(read_attribute(:locales), fallback: [])).uniq
  end

  # Translation languages — everything except the primary.
  def secondary_locales
    verto_locales - [ default_locale ]
  end

  def multilingual?
    verto_locales.size > 1
  end

  # The Verto content language to render for a viewer: the first preferred
  # candidate the Verto exists in, else its primary language.
  def display_locale_for(*preferred)
    preferred.flatten.compact.map(&:to_s).find { |l| verto_locales.include?(l) } || default_locale
  end

  # Returns a copy of `cards` with `translated` (an array, aligned per-card, of
  # { "text", "description", "options" }) merged into each card's i18n[locale].
  # Structural fields are untouched, so positional answer alignment is preserved.
  def self.merge_card_translations(cards, locale, translated)
    Array(cards).each_with_index.map do |card, i|
      t = translated[i]
      next card unless t.is_a?(Hash)

      entry = {
        "text"        => t["text"].to_s,
        "description" => t["description"].presence,
        "options"     => Array(t["options"]),
        # Scenario narrative pages and quiz answer feedback — respondent-facing
        # copy that would otherwise sit in the source language in every
        # secondary locale. Only written when the translation carried them, so
        # an ordinary question card's i18n entry stays the same shape as before.
        "pages"       => Array(t["pages"]).presence,
        "explanation" => t["explanation"].presence
      }.compact
      card.merge("i18n" => (card["i18n"] || {}).merge(locale.to_s => entry))
    end
  end

  # The creator's AI-report brief (goal / audience / length), stored as JSON
  # text so count-triggered regenerations reuse it. Always returns a Hash.
  def results_report_brief_data
    JSON.parse(results_report_brief.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  # This Verto's own palette (the three user-set roles). Legacy Vertos with no
  # palette fall back to the Playverto default so they render unchanged.
  def brand_palette
    read_attribute(:brand_palette).presence || BrandPalette::DEFAULT
  end

  def resolved_brand_palette
    BrandPalette.resolve(brand_palette)
  end

  # Accept only an uploaded data-image URL or an app-rooted image asset path,
  # so the value is safe to drop into an inline `style` attribute. Anything
  # else (or blank) clears the background.
  DATA_IMAGE_URL  = %r{\Adata:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+\z}
  ASSET_IMAGE_URL = %r{\A/[\w\-./]+\.(?:png|jpe?g|webp|svg|gif)\z}i
  # Same-origin Active Storage image paths — the organisation brand-asset
  # library (and logos). Broader than ASSET_IMAGE_URL because a signed-id path
  # segment can carry base64url characters ASSET_IMAGE_URL's charset excludes,
  # and blob URLs may append a query. Still anchored to the app's OWN
  # /rails/active_storage/ mount and an image extension, and it excludes quotes/
  # angles/whitespace so it stays safe inside an inline `url('…')` style.
  ACTIVE_STORAGE_IMAGE_URL = %r{\A/rails/active_storage/[^\s'"<>?]+\.(?:png|jpe?g|webp|svg|gif)(?:\?[^\s'"<>]*)?\z}i
  # Pexels CDN URLs (host-whitelisted) so editor-picked and auto-populated
  # stock photos survive the sanitizer. No quotes/parens, so it stays safe to
  # interpolate into an inline `url('…')` style.
  PEXELS_IMAGE_URL = %r{\Ahttps://images\.pexels\.com/[\w\-./]+\.(?:png|jpe?g|webp)(?:\?[\w%\-=&.+]*)?\z}i
  # Photographer-credit link target: a pexels.com page (the photographer's
  # profile). Doubles as the "link back to Pexels" the API guidelines ask for.
  PEXELS_CREDIT_URL = %r{\Ahttps://(?:www\.)?pexels\.com/[\w@\-./?=&%]*\z}i
  MAX_CREDIT_NAME   = 80
  MAX_LANE_LABEL    = 60 # branch name shown on the flow map (stored on the entry card)
  MAX_SCENARIO_PAGES       = 6
  MAX_SCENARIO_PAGE_LENGTH = 600

  # Every Range card is a 5-point scale — never 4, never 3. An even scale has
  # no true centre, so someone who genuinely sits in the middle is forced to
  # lean; and a deck mixing 3-, 4- and 5-point sliders can't be compared card
  # to card. The AI prompts ask for exactly 5, but a model can drift and the
  # importers map whatever the source form used (a Google Forms 1–4 linear
  # scale arrives as four labels), so the count is enforced here rather than
  # trusted upstream.
  RANGE_POINTS = 5

  # Names any stop a scale doesn't name itself — the same 5-point agree scale
  # the editor's "Add question" flow already fills a new range card with, so a
  # card repaired here is indistinguishable from one authored in the UI. Every
  # stop must end up named: an unlabelled one reads as a gap on the track, and
  # the editor's autosave drops blank labels, which would shorten the scale
  # again on the next save.
  RANGE_DEFAULT_LABELS = [
    "Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"
  ].freeze
  # Pexels video CDN (host-whitelisted) — the streamable mp4 for a card's
  # left-panel video. Posters are images.pexels.com URLs (sanitize_image_url).
  PEXELS_VIDEO_URL  = %r{\Ahttps://videos\.pexels\.com/[\w\-./]+\.mp4(?:\?[\w%\-=&.+]*)?\z}i

  # Cap on a stored base64 image. The client downscales uploads to ~1600px
  # WebP/JPEG (typically well under 1MB), so this is a defense-in-depth backstop
  # against an oversized blob slipping through: those inline data URLs are
  # re-materialised on every editor/preview/player render and were the main
  # memory driver behind the production 502s. Generous headroom over a normal
  # downscaled image; reject anything larger rather than persist it.
  MAX_BACKGROUND_DATA_URL_BYTES = 3_000_000

  # Coerce every range card's `options` to exactly RANGE_POINTS labels. Other
  # card types are untouched. Applied on save (see enforce_range_scale) so it
  # covers every authoring path — AI generation, the PDF/Forms/manual
  # importers, the CSV importer, templates and the editor's autosave — instead
  # of each one having to remember.
  def self.normalize_range_cards!(cards)
    Array(cards).map do |card|
      next card unless card.is_a?(Hash) && card["type"].to_s == "range"
      c = card.dup
      c["options"] = normalize_range_labels(c["options"])
      # Translations align to options POSITIONALLY, so a resized scale has to
      # resize its translations too — otherwise locale N shows label 4 at
      # stop 5. A translation that comes up short falls back to the primary
      # language for that stop, which is what the player renders anyway.
      if c["i18n"].is_a?(Hash)
        c["i18n"] = c["i18n"].transform_values do |tr|
          next tr unless tr.is_a?(Hash) && tr.key?("options")
          tr.merge("options" => normalize_range_labels(tr["options"], fill: c["options"]))
        end
      end
      c
    end
  end

  # Resize a range card's labels to exactly RANGE_POINTS, keeping the words
  # that are actually there:
  #
  #   5         → every stop stays put; only blanks get named
  #   6 or more → sampled evenly, so both endpoints survive
  #   4         → all four kept, the missing true centre opened up between them
  #   2 or 3    → spread across the scale, endpoints staying endpoints
  #   0         → `fill` (the default agree scale)
  #
  # Whatever the path, the gaps are then named from `fill` so no stop is left
  # blank, and the result is idempotent — re-normalising never shifts a label.
  #
  # A purely numeric scale keeps counting instead of gaining a word, so a
  # Google Forms 1–4 import reads "1 2 3 4 5" and not "1 2 Neutral 3 4".
  # `fill` names the stops this scale can't name itself: the default agree
  # scale for a card's own labels, and the primary-language labels when
  # normalising a translation, so a short translation falls through to the
  # primary word at that stop instead of rendering empty.
  def self.normalize_range_labels(labels, fill: RANGE_DEFAULT_LABELS)
    filler = Array(fill)
    raw    = Array(labels).map { |l| l.to_s.strip }

    # Already the right length: keep every stop exactly where it is and only
    # name the blanks. Re-spreading here would shuffle the whole scale when a
    # creator simply clears one label in the editor.
    return name_blank_stops(raw, filler) if raw.size == RANGE_POINTS

    given = raw.reject(&:blank?)
    return default_range_labels(filler)  if given.empty?
    return name_blank_stops(given, filler) if given.size == RANGE_POINTS

    # Numeric first, whichever direction it needs resizing: sampling a 1–7 run
    # the way words are sampled would print "1 3 4 6 7".
    numeric = resize_numeric_range_labels(given)
    return numeric if numeric

    spread = given.size > RANGE_POINTS ? downsample_range_labels(given) : upsample_range_labels(given)
    name_blank_stops(spread, filler)
  end

  # No stop is left nameless: an unlabelled point renders as a gap on the
  # track, and the editor's autosave would then drop it and shorten the scale.
  def self.name_blank_stops(labels, filler)
    labels.each_with_index.map do |label, i|
      label.presence || filler[i].to_s.strip.presence || RANGE_DEFAULT_LABELS[i]
    end
  end

  # Nothing to preserve: the translation falls back to the primary language,
  # and a card with no labels at all gets the default agree scale.
  def self.default_range_labels(fill)
    Array(fill).first(RANGE_POINTS).presence || RANGE_DEFAULT_LABELS.dup
  end

  # More labels than stops: pick RANGE_POINTS of them at even spacing. Both
  # endpoints are always included, so the scale keeps the range it described.
  def self.downsample_range_labels(given)
    last = given.size - 1
    (0...RANGE_POINTS).map { |i| given[(i * last / (RANGE_POINTS - 1.0)).round] }
  end

  # A consecutive integer run ("1".."4" or "1".."7", as a Google Forms linear
  # scale imports) is re-cut to RANGE_POINTS integers from its own starting
  # point: 1–4 grows to 1–5, 1–7 shrinks to 1–5, and 0–3 keeps its zero and
  # becomes 0–4. Anything else returns nil and takes the word path — including
  # a lone number, which says nothing about the intended run.
  def self.resize_numeric_range_labels(given)
    return nil if given.size < 2
    nums = given.map { |l| Integer(l, exception: false) }
    return nil if nums.any?(&:nil?)
    return nil unless nums.each_cons(2).all? { |a, b| b == a + 1 }
    (nums.first...(nums.first + RANGE_POINTS)).map(&:to_s)
  end

  # Fewer labels than stops: spread what we have so the creator's endpoints
  # stay endpoints. A 4-point scale keeps all four labels and opens up the true
  # centre it was missing (slot 2) — the case this whole rule exists for.
  # Remaining slots come back blank for name_blank_stops to fill.
  RANGE_UPSAMPLE_SLOTS = { 1 => [ 0 ], 2 => [ 0, 4 ], 3 => [ 0, 2, 4 ], 4 => [ 0, 1, 3, 4 ] }.freeze

  def self.upsample_range_labels(given)
    slots = Array.new(RANGE_POINTS)
    RANGE_UPSAMPLE_SLOTS.fetch(given.size).each_with_index { |slot, i| slots[slot] = given[i] }
    slots
  end

  # A single image value (background, card image, or one option_image): an
  # uploaded data-URL (size-capped), an app-rooted asset path, or a Pexels CDN
  # URL — anything else (or blank) returns nil.
  def self.sanitize_image_url(value)
    v = value.to_s.strip
    return nil if v.blank?
    return v if v.match?(ASSET_IMAGE_URL)
    return v if v.match?(ACTIVE_STORAGE_IMAGE_URL)
    return v if v.match?(PEXELS_IMAGE_URL)
    return v if v.match?(DATA_IMAGE_URL) && v.bytesize <= MAX_BACKGROUND_DATA_URL_BYTES
    nil
  end

  def self.sanitize_background_image(value)
    sanitize_image_url(value)
  end

  # A card left-panel video URL — only the Pexels video CDN is allowed.
  def self.sanitize_video_url(value)
    v = value.to_s.strip
    v.match?(PEXELS_VIDEO_URL) ? v : nil
  end

  # A photographer-credit link — only a pexels.com URL is allowed (rendered as
  # an href), anything else returns nil so the name shows without a link.
  def self.sanitize_credit_url(value)
    v = value.to_s.strip
    v.match?(PEXELS_CREDIT_URL) ? v : nil
  end

  # Scrub the `image`/`option_images` and the photographer-credit fields on each
  # card before persisting an editor PATCH, so a remote URL can only reach the
  # inline styles if it's a recognised, CSS-safe form and the credit link can
  # only point at Pexels. Other card fields are untouched. When a card has no
  # image, any orphaned credit is dropped.
  #
  # Pass `warnings:` (an array) to have it collect a short code per field that
  # had a real, present value which sanitizing dropped (e.g. an oversized or
  # unsupported upload) — so the caller can tell the editor something didn't
  # stick, instead of the drop being silent.
  def self.sanitize_cards_images!(cards, warnings: nil)
    seen_cids = Set.new
    Array(cards).map do |card|
      next card unless card.is_a?(Hash)
      c = card.dup
      # Every card carries a stable opaque id so answer-branching can target it
      # by cid (not array index). Backfill a missing cid AND de-dupe collisions:
      # two cards sharing a cid (from a duplicated/imported/hand-crafted deck)
      # would make a `{card: X}` route resolve to whichever card is last and
      # orphan the other, so any blank-or-already-seen cid is reassigned a fresh
      # unique one (the first occurrence keeps the id, so existing routes to it
      # still resolve).
      cid = c["cid"].to_s.strip
      cid = "c_#{SecureRandom.hex(4)}" while cid.blank? || seen_cids.include?(cid)
      seen_cids << cid
      c["cid"] = cid
      # Common Question provenance rides in from the editor's autosave payload
      # (the card row carries it as a data attribute so it survives the DOM
      # round-trip). Coerce to a positive integer or drop it: it's client-supplied
      # from here on, and the aggregator matches on it, so junk shouldn't be able
      # to settle in the cards JSON.
      %w[common_question_id common_question_set_id].each do |key|
        next unless c.key?(key)
        id = c[key].to_i
        id.positive? ? c[key] = id : c.delete(key)
      end
      c.delete("logic") unless c["logic"].is_a?(Hash) # drop malformed logic blocks
      # The unconditional flow pointer (any card type) — drop unless it's a valid
      # { "card" => cid } / { "end" => id } target (see LogicGraph.card_next).
      unless c["next"].is_a?(Hash) && (c["next"]["card"].to_s != "" || c["next"]["end"].to_s != "")
        c.delete("next")
      end
      # Optional branch name shown on the flow map (editor-only), stored on the
      # lane's entry card. Bounded plain text; blank ⇒ dropped (falls back to the
      # answer that opens the lane).
      if c.key?("lane_label")
        c["lane_label"] = c["lane_label"].to_s.strip.first(MAX_LANE_LABEL).presence
        c.delete("lane_label") if c["lane_label"].blank?
      end
      # First-class flow membership — an opaque flow id in the same format
      # sanitize_flows mints, or nothing. Whether the id names a REAL flow is
      # cross-checked in reconcile_flows! (it needs the flows list too).
      if c.key?("flow_id")
        fid = c["flow_id"].to_s.strip
        fid.match?(FLOW_ID_FORMAT) ? c["flow_id"] = fid : c.delete("flow_id")
      end
      # A range card's reaction-animation theme — only a known slug survives, and
      # only on a range card, so the helper always resolves to a real asset
      # folder (NpsHelper owns the theme list).
      if c.key?("range_theme")
        slug = c["range_theme"].to_s
        if c["type"].to_s == "range" && NpsHelper::RANGE_THEMES.include?(slug)
          c["range_theme"] = slug
        else
          c.delete("range_theme")
        end
      end
      # A range card's slider orientation — "auto" (heuristic decides at
      # render time) or an explicit creator override, and only on a range
      # card. Same allowlist-or-drop shape as range_theme above.
      if c.key?("slider_axis")
        axis = c["slider_axis"].to_s
        if c["type"].to_s == "range" && %w[auto horizontal vertical].include?(axis)
          c["slider_axis"] = axis
        else
          c.delete("slider_axis")
        end
      end
      # Scenario narrative pages — bounded count/length, and every page gets a
      # stable id (mirrors the cid backfill above) so translations align by
      # id rather than array index, which would silently scramble if a
      # creator reorders pages after translating. Dropped entirely on any
      # other type, same as range_theme above.
      if c["type"].to_s == "scenario"
        c["pages"] = Array(c["pages"]).first(MAX_SCENARIO_PAGES).filter_map do |p|
          next unless p.is_a?(Hash)
          text = p["text"].to_s.strip.first(MAX_SCENARIO_PAGE_LENGTH)
          next if text.blank?
          { "id" => p["id"].to_s.strip.presence || "pg_#{SecureRandom.hex(4)}", "text" => text }
        end
        if c["i18n"].is_a?(Hash)
          c["i18n"] = c["i18n"].transform_values do |tr|
            next tr unless tr.is_a?(Hash) && tr["pages"].present?
            tr = tr.dup
            tr["pages"] = Array(tr["pages"]).first(MAX_SCENARIO_PAGES).filter_map do |p|
              next unless p.is_a?(Hash) && p["id"].present?
              { "id" => p["id"].to_s, "text" => p["text"].to_s.strip.first(MAX_SCENARIO_PAGE_LENGTH) }
            end
            tr
          end
        end
      else
        c.delete("pages")
      end

      if c.key?("image")
        had_image = c["image"].present?
        c["image"] = sanitize_image_url(c["image"])
        warnings << "image" if warnings && had_image && c["image"].nil?
      end
      if c.key?("option_images")
        before = Array(c["option_images"])
        c["option_images"] = before.map { |u| sanitize_image_url(u) }
        warnings << "option_images" if warnings && before.any?(&:present?) && c["option_images"].any?(&:nil?)
      end

      # A card's left panel holds a photo OR a video. Scrub both; a poster only
      # makes sense alongside a video.
      if c.key?("video")
        c["video"] = sanitize_video_url(c["video"])
        c.delete("video") if c["video"].blank?
      end
      if c.key?("video_poster")
        c["video_poster"] = sanitize_image_url(c["video_poster"])
        c.delete("video_poster") if c["video"].blank? || c["video_poster"].blank?
      end

      if c.key?("image_credit") || c.key?("image_credit_url")
        if c["image"].present? || c["video"].present?
          c["image_credit"]     = c["image_credit"].to_s.strip.first(MAX_CREDIT_NAME).presence
          c["image_credit_url"] = sanitize_credit_url(c["image_credit_url"])
          c.delete("image_credit_url") if c["image_credit"].blank?
          c.delete("image_credit")     if c["image_credit"].blank?
        else
          c.delete("image_credit")
          c.delete("image_credit_url")
        end
      end
      c
    end
  end

  # Quiz: the card indices that are graded (carry a correct answer). Empty for a
  # non-quiz Verto, or a quiz whose questions are all still measurement-only.
  def graded_card_indices
    return [] unless quiz?
    QuizGrading.graded_indices(cards)
  end

  def quiz_question_count
    graded_card_indices.size
  end

  # Tokenisation: the card indices that award at least one token. Empty for a
  # non-tokenised Verto, or one whose cards are all still unawarded.
  def token_awarding_indices
    return [] unless tokenisation_enabled?
    TokenGrading.awarding_indices(cards)
  end

  def token_awarding_count
    token_awarding_indices.size
  end

  # This Verto's defined token type ids, e.g. ["gold", "coal"].
  def token_type_ids
    Array(token_types).map { |t| t["id"] }.compact
  end

  MAX_TOKEN_TYPES  = 8
  MAX_TOKEN_NAME   = 40
  MAX_TOKEN_ICON   = 8

  # Coerce creator-submitted token type definitions into a safe, bounded
  # array of {"id", "name", "icon"} before persisting: caps the count, trims
  # name/icon length, drops entries with no name, and assigns a stable id to
  # any entry that doesn't already have one (a fresh row from the editor) —
  # so cards that already reference an id by name change never break.
  def self.sanitize_token_types(value)
    Array(value).filter_map do |entry|
      next unless entry.is_a?(Hash)
      name = entry["name"].to_s.strip.first(MAX_TOKEN_NAME)
      next if name.blank?
      id   = entry["id"].to_s.strip.presence || SecureRandom.hex(4)
      icon = entry["icon"].to_s.strip.first(MAX_TOKEN_ICON).presence || "⭐"
      { "id" => id, "name" => name, "icon" => icon }
    end.first(MAX_TOKEN_TYPES)
  end

  def archive!
    update!(deleted_at: Time.current)
  end

  # ── Publish lifecycle ──────────────────────────────────────────────────────
  # Publishing mints a publish_token; unpublishing stamps unpublished_at and
  # leaves the token alone, so re-publishing restores the same /play link
  # (printed QR codes keep working). A Verto is therefore live only while it has
  # a token AND has not been taken down.
  def published?
    publish_token.present? && unpublished_at.nil?
  end

  # Published once, currently taken down.
  def unpublished?
    publish_token.present? && unpublished_at.present?
  end

  # Taken down after collecting responses. Results are kept, but the deck can
  # never be edited again (see editing_locked?), so this is a terminal "closed"
  # state rather than a return to draft.
  def closed?
    unpublished? && responses.exists?
  end

  # Back to a fully editable draft: taken down before anyone answered, so
  # there's nothing for a deck change to misalign.
  def reverted_to_draft?
    unpublished? && !responses.exists?
  end

  # Structural edits are locked while a Verto is live, and STAY locked once it
  # has collected responses even after being taken down: answers are keyed by
  # card index, so adding, removing or reordering cards silently misaligns every
  # later answer already stored. This — not published? — is the real editing
  # boundary, and every write path guards on it.
  def editing_locked?
    published? || responses.exists?
  end

  # Reachable by a respondent at /play/:token (or a partner share link): live,
  # and not archived. The single boundary every public player action guards on.
  def playable?
    published? && !deleted?
  end

  # The /play/:token segment to put in front of a respondent. Both the slug and
  # the publish_token resolve the same Verto (PlayerController#load_survey_and_share),
  # but a creator who bothered to set a custom link wants THAT one on the QR code
  # and anywhere else the link is handed out — it's the memorable one, and it
  # survives being read off a printed page. nil until published.
  def public_link_key
    return nil unless published?

    slug.presence || publish_token
  end

  # A same-organisation copy for the dashboard's "Duplicate" action. Always
  # lands in Drafts regardless of the source's status: publish_token,
  # published_at and slug share the /play/:token unique-index namespace, so
  # they're left nil rather than copied, and the results-report/summary
  # columns are generated from a specific run of responses the copy doesn't
  # have. `cards` is round-tripped through JSON so the copy owns its own
  # option/i18n arrays instead of sharing the source's in-memory objects. Card
  # cids are regenerated and every branching route/default rewritten old→new,
  # so the copy's routes point at the COPY's cards, never the original's.
  def duplicate!
    # Cards and flows must be remapped with the SAME cid map: a flow's exit can
    # point at a card, and the copy's exit has to follow the copy's fresh cid.
    dup_cards = JSON.parse(cards.to_json)
    dup_flows = JSON.parse(flows_list.to_json)
    self.class.remap_card_logic!(dup_cards, dup_flows)
    organisation.surveys.create!(
      title:                   self.class.append_copy_suffix(title),
      description:             description,
      theme:                   self.class.append_copy_suffix(theme),
      audience_age:            audience_age,
      key_insight:             key_insight,
      cards:                   dup_cards,
      flows:                   dup_flows,
      brand_palette:           read_attribute(:brand_palette),
      background_image:        background_image,
      default_locale:          default_locale,
      locales:                 locales,
      quiz:                    quiz,
      logic:                   logic,
      end_screens:             read_attribute(:end_screens),
      render_mode:             render_mode,
      show_results_comparison: show_results_comparison,
      tokenisation_enabled:    tokenisation_enabled,
      token_types:             token_types,
      compare_note:            compare_note,
      thankyou_title:          thankyou_title,
      thankyou_body:           thankyou_body,
      forward_url:             forward_url,
      forward_label:           forward_label,
      consent_text:            consent_text,
      consent_image:           consent_image,
      consent_image_credit:    consent_image_credit,
      consent_image_credit_url: consent_image_credit_url
    )
  end

  # Give every card a fresh cid and rewrite each branching target (route +
  # default) from the old cid to the new one, so a duplicated deck's routes
  # stay internally consistent. Targets whose old cid isn't in the deck (an
  # unexpected dangling route) are left as-is; the player fails them safe to
  # the linear next card. Pass the deck's flows too and each flow's card exit
  # is rewritten through the same map (flow ids themselves are survey-scoped,
  # so they and the cards' flow_id memberships copy verbatim). Mutates and
  # returns `cards`.
  def self.remap_card_logic!(cards, flows = nil)
    cards  = Array(cards)
    id_map = {}
    used   = Set.new
    cards.each do |card|
      next unless card.is_a?(Hash)
      old   = card["cid"].to_s
      fresh = "c_#{SecureRandom.hex(4)}"
      fresh = "c_#{SecureRandom.hex(4)}" while used.include?(fresh) # guarantee uniqueness
      used << fresh
      id_map[old] = fresh if old.present?
      card["cid"] = fresh
    end
    cards.each do |card|
      next unless card.is_a?(Hash)
      if card["logic"].is_a?(Hash)
        logic = card["logic"]
        Array(logic["routes"]).each { |route| remap_logic_target!(route["to"], id_map) if route.is_a?(Hash) }
        remap_logic_target!(logic["default"], id_map)
      end
      remap_logic_target!(card["next"], id_map) # the unconditional flow pointer
    end
    Array(flows).each { |f| remap_logic_target!(f["exit"], id_map) if f.is_a?(Hash) }
    cards
  end

  def self.remap_logic_target!(target, id_map)
    return unless target.is_a?(Hash) && target["card"].present?
    target["card"] = id_map[target["card"]] if id_map.key?(target["card"])
  end

  def self.append_copy_suffix(value)
    value.present? ? "#{value} (Copy)" : value
  end

  # The compare-results promise shown on the welcome card. Falls back to the
  # default copy when the creator hasn't customised it.
  def compare_note_text
    compare_note.presence || I18n.t("player.compare_promise")
  end

  # Thank-you screen copy shown after Finish. Both fall back to the default
  # localized copy when the creator hasn't set their own.
  def thankyou_title_text
    thankyou_title.presence || I18n.t("player.thank_you_title")
  end

  def thankyou_body_text
    thankyou_body.presence || I18n.t("player.thank_you_from", org: organisation.name)
  end

  def forward_url?
    forward_url.present?
  end

  # ── End screens (answer-branching) ─────────────────────────────────────────
  # A branch can finish on its own thank-you screen (e.g. a per-hub Stripe link)
  # instead of the shared one. The built-in "default" screen stays backed by the
  # legacy thankyou_* / forward_url columns (so the existing single thank-you is
  # unchanged); extra screens live in the end_screens JSON column.
  MAX_END_SCREENS = 12
  MAX_END_TITLE   = 80
  MAX_END_BODY    = 400
  MAX_END_LABEL   = 40
  DEFAULT_END_ID  = "default"

  def default_end_screen
    {
      "id" => DEFAULT_END_ID,
      "title" => thankyou_title_text,
      "body" => thankyou_body_text,
      "forward_url" => forward_url.presence,
      "forward_label" => forward_label.presence
    }
  end

  def extra_end_screens
    Array(read_attribute(:end_screens)).filter_map do |s|
      next unless s.is_a?(Hash) && s["id"].to_s.present? && s["id"].to_s != DEFAULT_END_ID
      {
        "id" => s["id"].to_s,
        "title" => s["title"].to_s.strip.presence || I18n.t("player.thank_you_title"),
        "body" => s["body"].to_s.strip.presence || I18n.t("player.thank_you_from", org: organisation.name),
        "forward_url" => s["forward_url"].presence,
        "forward_label" => s["forward_label"].to_s.strip.presence
      }
    end
  end

  # The full list: the built-in default first, then any extra branch screens.
  def end_screens_list
    [ default_end_screen ] + extra_end_screens
  end

  def end_screen(id)
    end_screens_list.find { |s| s["id"] == id.to_s } || default_end_screen
  end

  def end_screen_ids
    end_screens_list.map { |s| s["id"] }
  end

  # Coerce creator-submitted extra end screens into a safe, bounded array. The
  # "default" id is reserved for the built-in screen, so it's dropped here.
  def self.sanitize_end_screens(value)
    Array(value).filter_map do |entry|
      next unless entry.is_a?(Hash)
      id = entry["id"].to_s.strip.presence || "es_#{SecureRandom.hex(4)}"
      next if id == DEFAULT_END_ID
      title = entry["title"].to_s.strip.first(MAX_END_TITLE)
      body  = entry["body"].to_s.strip.first(MAX_END_BODY)
      fwd   = sanitize_forward_url(entry["forward_url"])
      next if title.blank? && body.blank? && fwd.blank?
      {
        "id" => id,
        "title" => title.presence,
        "body" => body.presence,
        "forward_url" => fwd,
        "forward_label" => entry["forward_label"].to_s.strip.first(MAX_END_LABEL).presence
      }.compact
    end.first(MAX_END_SCREENS)
  end

  # ── Flows (first-class named branches) ────────────────────────────────────
  # A flow is a named, coloured group of cards a routed answer can enter (e.g.
  # UK / UAE / USA regional question sets). Membership rides on each card as
  # `flow_id` (allowlisted in sanitize_cards_images!); this array holds only
  # the authoring metadata. FlowCompiler compiles membership + exit down to the
  # per-card `next` pointers the player already resolves, so play-time
  # semantics don't change. Flows supersede the flow map's older `lane_label`
  # (which remains as a read-only fallback for hand-wired decks).
  MAX_FLOWS      = 12
  MAX_FLOW_NAME  = MAX_LANE_LABEL
  # An opaque `f_`-prefixed token. Server/client mint hex, but any bounded
  # DOM/JSON-safe id is accepted (readable ids like "f_uk" are fine — cids
  # aren't format-constrained either, and the id never renders as copy).
  FLOW_ID_FORMAT = /\Af_[a-z0-9_-]{1,24}\z/i
  # Mirrors the flow map's LANE_PALETTE (logic_map_controller.js) so stored
  # flow colours match what the map already paints for derived lanes.
  FLOW_COLORS = %w[#8B85FF #01EACB #F59E0B #F472B6 #38BDF8 #A3E635].freeze

  def flows_list
    Array(read_attribute(:flows))
  end

  # Coerce creator-submitted flows into a safe, bounded array: opaque `f_` ids
  # (backfilled and de-duped like card cids), bounded plain-text name, a colour
  # from a fixed shape, and a single-key exit target or none. Same
  # allowlist-or-drop posture as sanitize_end_screens above.
  def self.sanitize_flows(value)
    seen = Set.new
    Array(value).each_with_index.filter_map do |entry, i|
      next unless entry.is_a?(Hash)
      id = entry["id"].to_s.strip
      id = nil unless id.match?(FLOW_ID_FORMAT)
      id = "f_#{SecureRandom.hex(4)}" while id.blank? || seen.include?(id)
      seen << id
      name  = entry["name"].to_s.strip.first(MAX_FLOW_NAME).presence || "Flow #{i + 1}"
      color = entry["color"].to_s.match?(/\A#\h{6}\z/) ? entry["color"] : FLOW_COLORS[i % FLOW_COLORS.size]
      out = { "id" => id, "name" => name, "color" => color }
      exit_target = FlowCompiler.valid_exit(entry["exit"])
      out["exit"] = exit_target if exit_target
      out
    end.first(MAX_FLOWS)
  end

  # Cross-field cleanup: a card can only claim membership of a flow that
  # exists. Needs both sides of the pair, so it can't live inside
  # sanitize_cards_images! (cards-only) or sanitize_flows (flows-only).
  # Mutates and returns `cards`.
  def self.reconcile_flows!(cards, flows)
    known = Array(flows).filter_map { |f| f["id"] if f.is_a?(Hash) }.to_set
    Array(cards).each do |c|
      c.delete("flow_id") if c.is_a?(Hash) && c.key?("flow_id") && !known.include?(c["flow_id"])
    end
    cards
  end

  # When set, respondents must agree to this text before the first card.
  def consent_required?
    consent_text.present?
  end

  # How the player presents this Verto. "cards" is the default immersive,
  # animated experience; "form" keeps the same one-question-at-a-time flow but
  # strips the swipe gestures and game-like animation so it reads as a plain
  # questionnaire (see the .forms-mode CSS layer and the player root class).
  RENDER_MODES = %w[cards form].freeze

  def self.normalize_render_mode(value)
    RENDER_MODES.include?(value.to_s) ? value.to_s : "cards"
  end

  def forms_mode?
    render_mode == "form"
  end

  # Coerce a creator-entered website into a safe http(s) URL for the
  # forward-to-website CTA on the thank-you screen. Adds a scheme when missing;
  # returns nil for blank or non-http(s) input so the CTA simply doesn't show.
  def self.sanitize_forward_url(value)
    v = value.to_s.strip
    return nil if v.blank?
    v = "https://#{v}" unless v.match?(%r{\Ahttps?://}i)
    uri = URI.parse(v)
    (uri.is_a?(URI::HTTP) && uri.host.present?) ? v : nil
  rescue URI::InvalidURIError
    nil
  end

  def slug?
    slug.present?
  end

  # Coerce creator input into a URL-safe slug for the optional vanity
  # /play/:slug link — lowercase, non-alphanumeric runs collapsed to a single
  # hyphen, leading/trailing hyphens trimmed, capped so the URL stays
  # reasonable. Blank input (or input with no alphanumerics) returns nil,
  # same "blank clears the setting" convention as consent_text.
  MAX_SLUG_LENGTH = 60
  def self.normalize_slug(value)
    slug = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
    slug.first(MAX_SLUG_LENGTH).delete_suffix("-").presence
  end

  # True when `value` is already in use anywhere in the /play/:token
  # namespace — this Verto's own publish_token, another Verto's slug or
  # publish_token, or a share token — so a creator-chosen slug can never
  # make PlayerController#load_survey_and_share resolve ambiguously.
  def self.slug_taken?(value, excluding_id: nil)
    return false if value.blank?
    Survey.where.not(id: excluding_id).exists?(slug: value) ||
      Survey.where.not(id: excluding_id).exists?(publish_token: value) ||
      SurveyShare.exists?(share_token: value)
  end

  # A "responder" is anyone who answered at least one question (not just those
  # who submitted). Counted in SQL off the denormalised `answered` flag, so this
  # never loads response rows / answers JSON (the dashboard computes these once
  # as grouped counts; this is the cheap single-survey fallback).
  def responders_count
    responses.where(answered: true).count
  end

  # Of the responders, the percentage who completed (submitted) the Verto.
  # nil when there are no responders yet.
  def completion_rate
    total = responders_count
    return nil if total.zero?
    (responses.where(answered: true, status: "completed").count * 100.0 / total).round
  end

  private

  def enforce_range_scale
    self.cards = self.class.normalize_range_cards!(cards)
  end
end
