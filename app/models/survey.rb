class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy
  # Named share links — extra /play/ addresses for this Verto, each with its own
  # respondent-facing overrides. See SurveyLink.
  has_many :survey_links, dependent: :destroy
  # Explicit open/close cycles of running the same Verto again to measure
  # change — see start_next_wave! for why these are real records rather than
  # a derived time window.
  has_many :survey_waves, -> { order(:position) }, dependent: :destroy
  has_many :partnership_vertos, dependent: :destroy
  has_many :report_renders, dependent: :destroy
  # Appeals filed against this Verto's rejected uploads — see
  # ImageReviewRequest and ImageAppealsController.
  has_many :image_review_requests, dependent: :destroy
  has_many :flow_generations, dependent: :destroy
  # Builds outlive the Verto they produced — they're the account's generation
  # log, deleted with the organisation, not the survey. Nullify rather than
  # nothing because verto_builds.survey_id carries a real FK: without this,
  # destroying a survey that a build points at raises InvalidForeignKey
  # (bitten in production by verto:import_csv rebuilding an org whose
  # placeholder Verto was wizard-built).
  has_many :verto_builds, dependent: :nullify
  # The Verto's Ask Verto consent record. Destroyed with it, so a deleted Verto
  # cannot leave a corpus entry that still reads as citable.
  has_one :corpus_entry, dependent: :destroy
  # The leaderboard's anonymous names. Scoped to the Verto (a name is an
  # identity on ONE board) and gone with it.
  has_many :player_aliases, dependent: :destroy

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

  # An option label's own emoji belongs in that option's icon tile, not beside
  # its words. Same guard as above and for the same reason: an option label is
  # the answer key for responses already collected, so a live Verto is never
  # rewritten. See hoist_option_label_emoji! for the full rules.
  before_save :hoist_option_label_emoji, if: -> { will_save_change_to_cards? && !published? }

  # Inline base64 images never reach a column. CardImageStore and the backfill
  # task moved the EXISTING data-URLs out (P1-7), but the door stayed open:
  # sanitize_image_url still accepts a data-URL, so every write path — the
  # editor's upload fallback, background and consent images, imports, generated
  # decks — could put megabytes of base64 straight back. Cleaning up history
  # without closing the door just means doing it again.
  #
  # Here rather than in the sanitizers because it catches every path at once,
  # including the ones no sanitizer covers, and because it needs a persisted
  # survey to attach a blob to.
  before_save  :externalize_inline_images
  after_create :externalize_inline_images_after_create

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
  # The extensions a same-origin image path may end in. Named once and
  # interpolated into the two patterns below, because uploaders have to name a
  # blob so that it PASSES those patterns (see Survey.image_extension?) — and a
  # rule spelled out separately in each place that needs it is how BUG-031/032
  # happened. `image/jpeg` is stored as `.jpg`, but a creator's own file may
  # well be `.jpeg`, so both are accepted.
  IMAGE_EXTENSIONS = %w[png jpg jpeg webp svg gif].freeze
  IMAGE_EXT_GROUP  = "(?:#{IMAGE_EXTENSIONS.join('|')})".freeze
  ASSET_IMAGE_URL = %r{\A/[\w\-./]+\.#{IMAGE_EXT_GROUP}\z}i
  # Same-origin Active Storage image paths — the organisation brand-asset
  # library (and logos). Broader than ASSET_IMAGE_URL because a signed-id path
  # segment can carry base64url characters ASSET_IMAGE_URL's charset excludes,
  # and blob URLs may append a query. Still anchored to the app's OWN
  # /rails/active_storage/ mount and an image extension, and it excludes quotes/
  # angles/whitespace so it stays safe inside an inline `url('…')` style.
  ACTIVE_STORAGE_IMAGE_URL = %r{\A/rails/active_storage/[^\s'"<>?]+\.#{IMAGE_EXT_GROUP}(?:\?[^\s'"<>]*)?\z}i
  # Same-origin Active Storage animation JSON — the ONLY form a card `lottie`
  # value may take. Pasted LottieFiles URLs are fetched, scrubbed and stored by
  # CardLottieStore first (see there for why hotlinking was rejected), so an
  # external URL reaching this sanitiser is always dropped.
  ACTIVE_STORAGE_LOTTIE_URL = %r{\A/rails/active_storage/[^\s'"<>?]+\.json(?:\?[^\s'"<>]*)?\z}i
  # Pexels CDN URLs (host-whitelisted) so editor-picked and auto-populated
  # stock photos survive the sanitizer. No quotes/parens, so it stays safe to
  # interpolate into an inline `url('…')` style.
  PEXELS_IMAGE_URL = %r{\Ahttps://images\.pexels\.com/[\w\-./]+\.(?:png|jpe?g|webp)(?:\?[\w%\-=&.+]*)?\z}i
  # Photographer-credit link target: a pexels.com page (the photographer's
  # profile). Doubles as the "link back to Pexels" the API guidelines ask for.
  PEXELS_CREDIT_URL = %r{\Ahttps://(?:www\.)?pexels\.com/[\w@\-./?=&%]*\z}i
  MAX_CREDIT_NAME   = 80
  MAX_LANE_LABEL    = 60 # branch name shown on the flow map (stored on the entry card)
  MAX_CARD_SUBJECT  = 60 # CardSubjectExtractor's photographable-noun-phrase stamp
  MAX_SCENARIO_PAGES       = 6
  MAX_SCENARIO_PAGE_LENGTH = 600
  # The plain-language "what this card tells you" line in the Why panel. Free
  # text, so bounded rather than allowlisted — the competency and condition
  # beside it are checked against Framework instead.
  MAX_OUTCOME_LENGTH       = 200
  # Card types whose content is stored as `pages` — a bounded array of
  # { id, text }. They share one sanitiser, one page-turn widget
  # (scenario_controller.js) and the same id-keyed translation handling.
  PAGED_TYPES = %w[scenario consent_gate].freeze

  # Card types whose options can carry per-option visual overrides
  # (`option_styles`: color / icon / emoji). The tile-and-label answer shapes —
  # scale, swipe and free-text types have no per-option tile to style.
  OPTION_STYLE_TYPES = %w[multiple_choice select_many prioritise yes_no select_one_grid select_many_grid scenario].freeze

  # ── Verto typeface ───────────────────────────────────────────────────────
  # The font a Verto is set in, picked in the Design panel beside its colours.
  # Deliberately the SAME seven families the rich-text toolbar already offers
  # per text selection (RichTextSanitizer::FONT_CLASSES is the authority, so
  # the two can't drift): every one is self-hosted under public/fonts and
  # already loaded, so a Verto font costs no extra request and needs nothing
  # added to the CSP. The stored value is the class token; nil = the platform
  # default. The CSS stack lives here because the browser needs a real
  # font-family value, not a class, when it comes through a custom property.
  BRAND_FONTS = {
    "font-abeezee"  => { label: "ABeeZee", stack: %('ABeeZee', sans-serif) },
    "font-alata"    => { label: "Alata",   stack: %('Alata', sans-serif) },
    "font-poppins"  => { label: "Poppins", stack: %('Poppins', sans-serif) },
    "font-lora"     => { label: "Lora",    stack: %('Lora', serif) },
    "font-spectral" => { label: "Spectral", stack: %('Spectral', serif) },
    "font-anton"    => { label: "Anton",   stack: %('Anton', sans-serif) },
    "font-caveat"   => { label: "Caveat",  stack: %('Caveat', cursive) }
  }.freeze

  # Allowlist-or-nil, the same shape every other creator-supplied style value
  # takes — the value reaches an inline `style` attribute, so nothing that
  # isn't a known token may pass.
  def self.sanitize_brand_font(value)
    v = value.to_s.strip
    BRAND_FONTS.key?(v) ? v : nil
  end

  # The CSS font stacks for this Verto, or nil where it uses the default.
  # `brand_font` is the BODY face and the base for the whole Verto;
  # `brand_font_heading` overrides it for questions and titles only. A blank
  # heading font means headings follow the body — which is what every Verto
  # did before headings were separable, so nothing changes until it's set.
  def brand_font_stack
    BRAND_FONTS.dig(brand_font.to_s, :stack)
  end

  def brand_font_heading_stack
    BRAND_FONTS.dig(brand_font_heading.to_s, :stack)
  end

  # Free-text answer length. This used to be a hardcoded 200 in the card
  # partial, and it was advisory only — no maxlength on the textarea and no
  # server check anywhere, so the counter turned pink and the answer saved in
  # full regardless. Now it's per-card and actually enforced.
  # A rating card is always five stars. Answers are stored as the star NUMBER
  # and results count 1..5, so this is the card type's contract rather than a
  # function of how many captions a particular card happens to carry — a card
  # with only min/max labels is still a five-star card.
  RATING_STARS = 5

  DEFAULT_FREE_TEXT_LIMIT = 200
  # Bounds on what a creator can choose. The floor keeps a limit from being set
  # so low the question can't be answered; the ceiling keeps a single answer from
  # becoming the thing that bloats the answers JSON.
  FREE_TEXT_LIMIT_RANGE = (20..2000).freeze
  # Offered in the editor. The default is in the list so the control always shows
  # the current value, including on decks that never set one.
  FREE_TEXT_LIMIT_PRESETS = [ 80, 140, DEFAULT_FREE_TEXT_LIMIT, 500, 1000 ].freeze

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
  # The stops a scale can't name itself are named from `fill` — resolved in
  # `locale` (a Verto's default_locale from enforce_range_scale), so a French
  # deck's repaired stop says "Plutôt d'accord", not "Agree". English constant
  # as the last-resort fallback, same as everywhere else.
  def self.localized_range_labels(locale = nil)
    labels = I18n.t("defaults.range", locale: locale.presence || I18n.locale,
                                      default: RANGE_DEFAULT_LABELS)
    return RANGE_DEFAULT_LABELS unless labels.is_a?(Array) && labels.size == RANGE_DEFAULT_LABELS.size
    labels.map(&:to_s)
  rescue I18n::InvalidLocale
    RANGE_DEFAULT_LABELS
  end

  def self.normalize_range_cards!(cards, fill: RANGE_DEFAULT_LABELS)
    Array(cards).map do |card|
      next card unless card.is_a?(Hash) && card["type"].to_s == "range"
      c = card.dup
      c["options"] = normalize_range_labels(c["options"], fill: fill)
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

  # Whether a blob filename already ends in an extension ACTIVE_STORAGE_IMAGE_URL
  # accepts. Active Storage serves a blob at /rails/active_storage/…/<filename>,
  # so the name a file was uploaded under decides whether its path survives
  # sanitize_image_url — an image called "logo" or "holiday.jfif" is a perfectly
  # valid PNG/JPEG by content type (which is what the uploaders validate) but
  # yields a path the card sanitiser drops. Uploaders call this to give a blob a
  # name that will pass, rather than re-listing the extensions themselves.
  def self.image_extension?(filename)
    IMAGE_EXTENSIONS.include?(File.extname(filename.to_s).delete_prefix(".").downcase)
  end

  # A card left-panel video URL — only the Pexels video CDN is allowed.
  def self.sanitize_video_url(value)
    v = value.to_s.strip
    v.match?(PEXELS_VIDEO_URL) ? v : nil
  end

  # A card left-panel Lottie animation — only a same-origin stored copy is
  # allowed (CardLottieStore ingests the pasted LottieFiles URL).
  def self.sanitize_lottie_url(value)
    v = value.to_s.strip
    v.match?(ACTIVE_STORAGE_LOTTIE_URL) ? v : nil
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
      # Framework provenance. SurveyGenerator#normalize_framework! already
      # allowlists these, but that only runs on generation — this path now
      # receives them from the editor's autosave too, so the same rule has to
      # hold here or a crafted PATCH could put anything in the "Why this card?"
      # panel. Same allowlist-or-drop shape as range_theme below. `outcome` is
      # free text by design, so it is capped rather than checked.
      c.delete("competency") if c.key?("competency") && !Framework.competency?(c["competency"])
      c.delete("condition")  if c.key?("condition")  && !Framework.condition?(c["condition"])
      if c.key?("outcome")
        outcome = c["outcome"].to_s.strip.first(MAX_OUTCOME_LENGTH)
        outcome.present? ? c["outcome"] = outcome : c.delete("outcome")
      end

      # Which opt-in demographic question a card is (heritage/neurodiversity) —
      # only a known key survives, and only on a card that is actually flagged
      # demographic. The flag requirement means a crafted payload can't hang a
      # key on an arbitrary card without also flagging it demographic (which
      # costs it imagery and buys consent gating — no win); the answer sync
      # additionally validates every stored value against the card's own
      # options. Same allowlist-or-drop shape as range_theme below.
      if c.key?("demographic_key")
        key = c["demographic_key"].to_s
        if c["demographic"] && DemographicQuestions::DEMOGRAPHIC_KEYS.include?(key)
          c["demographic_key"] = key
        else
          c.delete("demographic_key")
        end
      end
      # Which country's heritage taxonomy this card was built from — provenance,
      # so the editor can tell a tailored card from the global nine and rebuild
      # it when the Verto's audience country changes. Only a real WorldRegions
      # code survives, and only on the heritage card itself: it says nothing
      # about any other card, and a crafted payload hanging it elsewhere would
      # make the rebuild pick the wrong card. Same allowlist-or-drop shape as
      # demographic_key above.
      if c.key?("heritage_country")
        code = c["heritage_country"].to_s.upcase
        if c["demographic"] && c["demographic_key"].to_s == "heritage" && WorldRegions.valid?(code)
          c["heritage_country"] = code
        else
          c.delete("heritage_country")
        end
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
      # Where a card's image sits vertically inside the MOBILE header strip.
      # 0-100, a percentage handed straight to background-position; 50 (centre)
      # is the default and is stored as nothing. The card image is a 9:16
      # portrait while the mobile hero is roughly 3:1, so `cover` + centre shows
      # only the middle band of a tall photo and a face at the top of the frame
      # is simply gone — "to drag the image up and down to choose the perfect
      # spot for mobile headers. This would be a huge win" (18 Aug).
      #
      # A stored position rather than a second crop: the original stays intact,
      # so it can be re-adjusted later and every other surface keeps the whole
      # image.
      if c.key?("focal_y")
        raw   = c["focal_y"]
        # `.to_f` alone would turn any junk into 0.0, i.e. silently pin the
        # header to the top of the image. A value that isn't a number is a
        # value we don't understand — drop it and use the centre.
        numeric = raw.is_a?(Numeric) || raw.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)
        focal   = numeric ? raw.to_f.clamp(0, 100).round : nil
        if c["image"].present? && focal && focal != 50
          c["focal_y"] = focal
        else
          c.delete("focal_y")
        end
      end

      # Animation backdrop — the colour or image behind a Lottie / range
      # animation, overriding the Verto-wide --brand-panel for this one card.
      # Only meaningful where an animation actually fills the panel (a photo or
      # video covers the panel itself), so it is dropped anywhere else rather
      # than kept as dead data that would surprise whoever adds media later.
      # Same allowlist-or-drop shape as range_theme above.
      if c.key?("media_bg")
        bg  = c["media_bg"].is_a?(Hash) ? c["media_bg"] : {}
        out = {}
        color = bg["color"].to_s
        out["color"] = "#" + color.strip.delete_prefix("#").downcase if BrandPalette.valid_hex?(color)
        if (img = sanitize_image_url(bg["image"])).present?
          out["image"] = img
        end
        # Reads the card's OWN lottie value, which at this point has not been
        # through sanitize_lottie_url yet — a card carrying an off-allowlist
        # animation would have its backdrop kept and the animation dropped.
        # Check the value the way that sanitiser will.
        animated = c["type"].to_s == "range" || sanitize_lottie_url(c["lottie"]).present?
        if animated && out.any?
          c["media_bg"] = out
        else
          c.delete("media_bg")
        end
      end

      # Rich-text layer: presentation-only HTML twins of the plain text
      # fields (text_html / description_html / options_html; page html is
      # handled in the PAGED_TYPES block below). Every value passes
      # RichTextSanitizer.clean_equivalent — sanitised to the tag/class
      # allowlist AND required to still read as its plain twin — so grading,
      # aggregation, exports, AI and i18n (all keyed off the plain layer) can
      # never disagree with what respondents saw. Translations stay plain:
      # any *_html inside i18n is stripped outright.
      if (html = RichTextSanitizer.clean_equivalent(c["text_html"], c["text"]))
        c["text_html"] = html
      else
        c.delete("text_html")
      end
      if (html = RichTextSanitizer.clean_equivalent(c["description_html"], c["description"]))
        c["description_html"] = html
      else
        c.delete("description_html")
      end
      if c.key?("options_html")
        opts  = Array(c["options"])
        htmls = Array(c["options_html"]).first(opts.length).each_with_index.map do |h, i|
          RichTextSanitizer.clean_equivalent(h, opts[i])
        end
        htmls += [ nil ] * (opts.length - htmls.length) if htmls.length < opts.length
        htmls.any? ? c["options_html"] = htmls : c.delete("options_html")
      end
      if c["i18n"].is_a?(Hash)
        c["i18n"] = c["i18n"].transform_values do |tr|
          tr.is_a?(Hash) ? tr.reject { |k, _| k.to_s.end_with?("_html") } : tr
        end
      end

      # Per-option visual overrides ({color, icon, emoji} or null, POSITIONAL
      # against `options` — like option_images, DOM order in the editor is the
      # alignment, so there is no splice bookkeeping here). Purely
      # presentational: answers still key off the option's label text. Same
      # allowlist-or-drop shape as range_theme below — hex via BrandPalette,
      # icon ids via OptionIconLibrary, emoji clamped like token icons.
      if c.key?("option_styles")
        if OPTION_STYLE_TYPES.include?(c["type"].to_s)
          limit  = c["type"].to_s == "yes_no" ? 2 : Array(c["options"]).length
          styles = Array(c["option_styles"]).first(limit).map do |entry|
            next nil unless entry.is_a?(Hash)
            out = {}
            color = entry["color"].to_s
            out["color"] = "#" + color.strip.delete_prefix("#").downcase if BrandPalette.valid_hex?(color)
            out["icon"]  = entry["icon"].to_s if OptionIconLibrary.valid_id?(entry["icon"].to_s)
            emoji = entry["emoji"].to_s.strip
            out["emoji"] = emoji.first(MAX_TOKEN_ICON) if emoji.present?
            out.presence
          end
          # Pad so positions keep meaning even when the tail is unstyled.
          styles += [ nil ] * (limit - styles.length) if styles.length < limit
          styles.any? ? c["option_styles"] = styles : c.delete("option_styles")
        else
          c.delete("option_styles")
        end
      end

      # A tap card's RESPONSE SCALE — the 2-6 answers a respondent chooses
      # between on each swipe statement, ordered most-negative first. Same
      # allowlist-or-drop shape as option_styles above, with one difference that
      # matters: `key` is not decoration, it is the value the answer is STORED
      # as (and what `tokens` and `correct` are keyed off), so it is minted when
      # missing and de-duplicated within the card exactly like `cid`, rather
      # than being allowed through as whatever the client sent.
      #
      # Anything short of a whole valid scale is dropped rather than half-kept:
      # TapScales.for_card falls back to the historic 3-point set when the key is
      # absent, which is a working card, whereas a one-button scale is not.
      #
      # Deliberately NOT gated on the card's current type, for the reason
      # option_images isn't either: a creator who builds a six-point scale, tries
      # Range to compare and switches back should find their scale, not the
      # default three. Only tap cards ever read the key, and every field in it is
      # bounded here whatever type it arrives on, so carrying it costs nothing.
      if c.key?("responses")
        seen = Set.new
        list = Array(c["responses"]).first(TapScales::MAX_RESPONSES).filter_map do |entry|
          next unless entry.is_a?(Hash)
          key = entry["key"].to_s.strip.downcase
          key = "r_#{SecureRandom.hex(4)}" while key.blank? || !key.match?(TapScales::KEY_FORMAT) || seen.include?(key)
          seen << key
          out = { "key" => key }
          label = entry["label"].to_s.strip.first(TapScales::MAX_LABEL)
          out["label"] = label if label.present?
          out["glyph"] = entry["glyph"].to_s if TapScales::GLYPHS.include?(entry["glyph"].to_s)
          out["icon"]  = entry["icon"].to_s  if OptionIconLibrary.valid_id?(entry["icon"].to_s)
          emoji = entry["emoji"].to_s.strip
          out["emoji"]  = emoji.first(MAX_TOKEN_ICON) if emoji.present?
          color = entry["color"].to_s
          out["color"]  = "#" + color.strip.delete_prefix("#").downcase if BrandPalette.valid_hex?(color)
          out["strong"] = true if entry["strong"]
          out
        end
        if list.length >= TapScales::MIN_RESPONSES
          c["responses"] = list
        else
          c.delete("responses")
        end
      end
      # Translated response labels align POSITIONALLY, exactly like `options`, so
      # a resized scale has to resize its translations too — otherwise locale N
      # shows response 4's words on response 5. A translation that comes up short
      # falls back to the primary label, which is what the player renders anyway.
      if c["i18n"].is_a?(Hash)
        size = Array(c["responses"]).length
        c["i18n"] = c["i18n"].transform_values do |tr|
          next tr unless tr.is_a?(Hash) && tr.key?("responses")
          next tr.except("responses") if size.zero?
          labels = Array(tr["responses"]).first(size)
                                         .map { |l| l.to_s.strip.first(TapScales::MAX_LABEL) }
          labels += [ "" ] * (size - labels.length) if labels.length < size
          tr.merge("responses" => labels)
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
      # Paged text — bounded count/length, and every page gets a stable id
      # (mirrors the cid backfill above) so translations align by id rather than
      # array index, which would silently scramble if a creator reorders pages
      # after translating. Shared by scenario (narrative before a choice) and
      # consent_gate (an information sheet before agreeing), which store pages
      # identically. Dropped entirely on any other type, same as range_theme.
      if PAGED_TYPES.include?(c["type"].to_s)
        c["pages"] = Array(c["pages"]).first(MAX_SCENARIO_PAGES).filter_map do |p|
          next unless p.is_a?(Hash)
          text = p["text"].to_s.strip.first(MAX_SCENARIO_PAGE_LENGTH)
          next if text.blank?
          page = { "id" => p["id"].to_s.strip.presence || "pg_#{SecureRandom.hex(4)}", "text" => text }
          # Rich-text layer for the page, same equivalence contract as
          # text_html below: presentation only, must still read as `text`.
          if (html = RichTextSanitizer.clean_equivalent(p["html"], text))
            page["html"] = html
          end
          page
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

      # Per-card free-text cap. Clamped into FREE_TEXT_LIMIT_RANGE rather than
      # rejected, and dropped when it equals the default so a deck only carries
      # the key when a creator actually changed it.
      if c.key?("char_limit")
        limit = c["char_limit"].to_i
        if limit.zero? || limit == DEFAULT_FREE_TEXT_LIMIT
          c.delete("char_limit")
        else
          c["char_limit"] = limit.clamp(FREE_TEXT_LIMIT_RANGE.min, FREE_TEXT_LIMIT_RANGE.max)
        end
      end

      # Explicit "this question awards no points". Coerced to a real boolean
      # because TokenGrading.awarding? tests for `false` exactly — a "false"
      # string arriving from JSON would otherwise read as truthy and award. Only
      # an explicit false is kept; absent (and true) both mean enabled, so
      # existing decks are untouched.
      if c.key?("tokens_enabled")
        enabled = ActiveModel::Type::Boolean.new.cast(c["tokens_enabled"])
        enabled == false ? c["tokens_enabled"] = false : c.delete("tokens_enabled")
      end

      if c.key?("image")
        had_image = c["image"].present?
        c["image"] = sanitize_image_url(c["image"])
        warnings << "image" if warnings && had_image && c["image"].nil?
      end
      if c.key?("option_images")
        before = Array(c["option_images"])
        after  = before.map { |u| sanitize_image_url(u) }
        c["option_images"] = after
        # Compared slot by slot, NOT array-wide. option_images is positional —
        # index i is statement i — so an empty slot means "this statement has no
        # picture", which is the ordinary state of any tap card where the creator
        # cleared one image or where only some statements were given one. The old
        # test ("something is present" AND "something is nil") read those blanks
        # as drops and fired on every autosave, telling the creator to re-upload
        # an image they had deliberately removed, forever, with nothing wrong.
        if warnings && before.each_with_index.any? { |u, i| u.present? && after[i].nil? }
          warnings << "option_images"
        end
      end

      # A card's left panel holds a photo OR a video OR a Lottie animation.
      # Scrub all three; a poster only makes sense alongside a video.
      if c.key?("video")
        c["video"] = sanitize_video_url(c["video"])
        c.delete("video") if c["video"].blank?
      end
      if c.key?("video_poster")
        c["video_poster"] = sanitize_image_url(c["video_poster"])
        c.delete("video_poster") if c["video"].blank? || c["video_poster"].blank?
      end
      if c.key?("lottie")
        had_lottie = c["lottie"].present?
        c["lottie"] = sanitize_lottie_url(c["lottie"])
        if c["lottie"].blank?
          c.delete("lottie")
          warnings << "lottie" if warnings && had_lottie
        else
          # Mirrors the client's exclusivity: applying an animation clears the
          # photo/video (and with them the credit fields, below). Warn on
          # this same as an outright-rejected image — a card should never
          # reach this branch with both set (the client never sends both,
          # and Shuffle is guarded against it too), so if one does, whatever
          # put it there deserves a visible flag, not a silent drop.
          warnings << "image" if warnings && c["image"].present?
          warnings << "video" if warnings && c["video"].present?
          c.delete("image")
          c.delete("video")
          c.delete("video_poster")
        end
      end

      # A slow, looping push-in/out on the card's own photo or Lottie — never
      # video (its own motion is enough) or range (the reaction set already
      # animates). Checked against image/lottie AFTER both are sanitised
      # above, so a card whose animation just got rejected doesn't keep a
      # flag for motion it no longer has anything to apply to.
      if c.key?("animate_asset")
        animatable = c["type"].to_s != "range" && (c["image"].present? || c["lottie"].present?)
        if animatable && c["animate_asset"] == true
          c["animate_asset"] = true
        else
          c.delete("animate_asset")
        end
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

      # CardSubjectExtractor's photographable-noun-phrase stamp, read by
      # AssetPopulator#card_query to anchor Pexels queries — provenance
      # metadata, not shown to a respondent, so it's simply bounded plain text
      # like lane_label/outcome above rather than tied to the card carrying an
      # image (a subject can be stamped before any image is picked, and
      # outlives a later image being cleared).
      if c.key?("subject")
        c["subject"] = c["subject"].to_s.strip.first(MAX_CARD_SUBJECT).presence
        c.delete("subject") if c["subject"].blank?
      end
      c
    end.then { |list| enforce_single_welcome(list, warnings: warnings) }
       .then { |list| hoist_consent_gate(list, warnings: warnings) }
  end

  # At most one welcome card per deck. Nothing enforced this: welcome_card was
  # pickable like any other type, so a second could be added — or any card
  # converted into one — and the player then greeted the respondent twice.
  #
  # Duplicates are DROPPED (keeping the first) rather than rejected, and the
  # choice is deliberate: decks with two welcome cards already exist, and a
  # validation error here would 422 their every autosave from now on — turning
  # a historical oddity into an editor that can no longer save. The drop is not
  # silent either: it pushes onto `warnings`, the same channel a rejected image
  # uses, which the editor surfaces as a save warning.
  def self.enforce_single_welcome(list, warnings: nil)
    seen = false
    list.filter_map do |c|
      next c unless c.is_a?(Hash) && c["type"].to_s == "welcome_card"
      if seen
        warnings << "duplicate_welcome" if warnings
        next nil
      end
      seen = true
      c
    end
  end

  # A consent gate must come before any card that captures an answer.
  #
  # It is an ordinary deck card, so a creator could put it at position four —
  # and /progress persists answers on every advance, so by the time the
  # respondent read the sheet and declined, three answers were already stored,
  # counted as a responder, and feeding the public aggregates. Declining is
  # supposed to mean their data is not collected.
  #
  # Non-question cards may still precede it: a welcome card or a points
  # checkpoint captures nothing, so "Hello → consent → questions" is both a
  # nicer flow and still safe. The rule is "before any QUESTION", not "first".
  #
  # Only reached from the editor's save path, and #update refuses any edit to a
  # Verto that is published or already has responses (editing_locked?), so a
  # deck being reordered here can have no stored answers to misalign — which
  # matters, because answers are keyed by card index.
  def self.hoist_consent_gate(list, warnings: nil)
    gate_at = list.index { |c| c.is_a?(Hash) && c["type"].to_s == "consent_gate" }
    return list if gate_at.nil?

    first_question = list.index { |c| c.is_a?(Hash) && CardTypes.question?(c["type"]) }
    return list if first_question.nil? || gate_at < first_question

    gate = list.delete_at(gate_at)
    # The gate is leaving its place in the deck, so any flow membership or
    # branch routing it carried is stale — FlowCompiler chains flow members in
    # deck order, and a hoisted gate still wearing its flow_id would splice the
    # gate into the flow's chain at the front and skip the question the route
    # actually pointed at. Same channel as the image warnings, so the editor
    # can tell the creator the deck was reshaped.
    gate.delete("next")
    gate.delete("flow_id")
    gate.delete("lane_label")
    warnings << "consent_gate_moved" if warnings
    list.insert(first_question, gate)
    list
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

  # Which deck position carries the "you'll earn points" intro.
  #
  # The creator's choice is STORED as a cid, so it follows its card through a
  # reorder — but it's RESOLVED to an index, because a deck built outside the
  # editor's save path (the demo seeder, a raw import) can have no cids at all,
  # and the intro still has to appear. Falls back to the welcome card, where it
  # used to be hardcoded, then to the first card.
  def token_intro_index
    return nil unless tokenisation_enabled?

    list = Array(cards)
    return nil if list.empty?

    wanted = token_intro_cid.presence
    if wanted
      found = list.index { |c| c.is_a?(Hash) && c["cid"].to_s == wanted }
      return found if found
    end

    list.index { |c| c.is_a?(Hash) && c["type"].to_s == "welcome_card" } || 0
  end

  # The cid of that card, when it has one — what the editor's picker marks as
  # selected. Nil on a deck whose cards predate cid backfilling; the picker only
  # offers cid-bearing cards, and the default above covers the rest.
  def token_intro_selected_cid
    idx = token_intro_index
    return nil if idx.nil?

    card = Array(cards)[idx]
    card.is_a?(Hash) ? card["cid"].presence : nil
  end

  # Cards a creator can pin the token intro to — anything with a cid.
  def token_intro_choices
    Array(cards).filter_map do |c|
      next unless c.is_a?(Hash) && c["cid"].present?
      [ c["cid"].to_s, c["type"].to_s, c["title"].presence || c["text"].presence ]
    end
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

  # Test Mode: /test/:token plays the Verto — drafts included — without
  # sign-in, records nothing, and stays current while the creator edits.
  # Independent of published?/editing_locked? by design; since no responses
  # are ever written through it, it can never flip the editing lock. The
  # /test/ namespace resolves ONLY by exact test_token, so it never interacts
  # with slug_taken?'s /play/ namespace guard.
  def test_playable?
    test_token.present? && !deleted?
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

  # A results-share token has been minted — distribution state, like
  # test_token/slug, so nothing here touches editing_locked? or published?.
  # The data being shared already exists regardless of whether /play is still
  # collecting more of it.
  def results_share_enabled?
    results_share_token.present?
  end

  # Reachable by anyone at /results/:token: a token exists, hasn't been
  # paused, and the Verto isn't archived. Deliberately NOT gated on
  # published? — a closed Verto's results stay shareable, and the owner
  # controls the whole thing explicitly either way.
  def results_share_live?
    results_share_enabled? && results_share_active? && !deleted?
  end

  # ── Respondent code ────────────────────────────────────────────────────────
  # An optional self-invented code ("your nickname and the day of the month you
  # were born") that links one person's answers across waves of the same Verto
  # without identifying them.
  #
  # Only ever stored as an HMAC. The key is derived per survey, so a digest is
  # comparable only WITHIN this Verto: the same code given to two Vertos yields
  # two unrelated digests, and a creator with database access can neither read a
  # code nor recognise someone across their other Vertos.

  MAX_RESPONDENT_CODE = 60

  def respondent_code_prompt_text
    respondent_code_prompt.presence || I18n.t("player.respondent_code_prompt_default")
  end

  # nil for anything that isn't a usable code, so a blank or whitespace-only
  # entry is simply "no code" rather than a digest everyone shares.
  def respondent_code_digest(code)
    normalised = self.class.normalize_respondent_code(code)
    return nil if normalised.blank?

    OpenSSL::HMAC.hexdigest("SHA256", respondent_code_key, normalised)
  end

  # The leaderboard identity digest — respondent_code_digest's sibling, same
  # posture: the raw browser-minted key is never stored, and the per-survey
  # key means a digest is comparable only within this Verto, so identities
  # can't be joined across surveys. nil for blank input ("no identity"), and
  # the length bound keeps an abusive payload from becoming HMAC fodder — a
  # legitimate key is a 36-char UUID.
  def player_key_digest(key)
    normalised = key.to_s.strip.first(80)
    return nil if normalised.blank?

    OpenSSL::HMAC.hexdigest("SHA256", player_key_hmac_key, normalised)
  end

  # Case and spacing shouldn't decide whether someone matches themselves — a
  # respondent typing "Sam 14" in wave two after "sam14" in wave one is the same
  # person, and the whole feature is worthless if that misses.
  def self.normalize_respondent_code(code)
    code.to_s.unicode_normalize(:nfkc).downcase.gsub(/\s+/, "").first(MAX_RESPONDENT_CODE)
  end

  # How many respondents gave a code that another response also gave — i.e. came
  # back. Counted in SQL; the digests never leave the database.
  def returning_respondents_count
    responses.where.not(respondent_code_digest: nil)
             .group(:respondent_code_digest)
             .having("COUNT(*) > 1")
             .count.size
  end

  # ── Waves ───────────────────────────────────────────────────────────────────
  # Explicit records the owner opens and closes, not a time window derived from
  # published_at/unpublished_at: those are single columns a re-publish
  # overwrites (#publish keeps the original published_at and nils
  # unpublished_at — no open/close history survives), and responses.completed_at
  # is server-receipt time, not answer time — the offline submit queue can drain
  # after the next wave has already opened, so a timestamp comparison would
  # misfile it. A response is stamped with the CURRENT wave once, at write time
  # (PlayerController#find_or_init_response), and that stamp never moves.
  #
  # Wave 1 stays implicit — no SurveyWave row — until start_next_wave! is first
  # called, at which point every response collected so far (survey_wave_id nil)
  # retroactively becomes wave 1's membership by backfill.

  def waved?
    survey_waves.exists?
  end

  # The wave any new response belongs to right now, or nil while wave 1 is
  # still implicit. At most one wave is ever open at a time — start_next_wave!
  # closes the previous one in the same transaction that opens the next.
  def current_wave
    survey_waves.find_by(closed_at: nil)
  end

  # Closes whatever wave is open and opens a new one, materialising the
  # implicit wave 1 (backfilling every pre-existing response into it) the
  # first time this is ever called. `label` is the owner's optional name for
  # the NEW wave; the one being closed keeps whatever label it already had.
  def start_next_wave!(label: nil)
    transaction do
      if waved?
        close_current_wave!
      else
        wave1 = survey_waves.create!(position: 1, opened_at: published_at || created_at)
        responses.where(survey_wave_id: nil).update_all(survey_wave_id: wave1.id)
        wave1.update!(closed_at: Time.current)
      end
      next_position = survey_waves.maximum(:position).to_i + 1
      survey_waves.create!(position: next_position, label: label.presence, opened_at: Time.current)
    end
  end

  def close_current_wave!
    current_wave&.update!(closed_at: Time.current)
  end

  # How many respondents in `wave` gave a code that also appears in an
  # EARLIER wave — i.e. came back for this run specifically, not merely
  # "answered more than once ever" (returning_respondents_count, whole-Verto).
  # Same discipline: counted in SQL, digests never leave the database.
  def wave_returning_count(wave)
    earlier_ids = survey_waves.where("position < ?", wave.position).pluck(:id)
    return 0 if earlier_ids.empty? # nothing can return before the first wave

    responses.where(survey_wave_id: wave.id)
             .where.not(respondent_code_digest: nil)
             .where(respondent_code_digest: responses.where(survey_wave_id: earlier_ids).select(:respondent_code_digest))
             .count
  end

  # ── Recently deleted cards ─────────────────────────────────────────────────
  # A bounded ring buffer of cards removed from the deck, so a deletion survives
  # the page reload that in-session undo can't. Not a versioning gem: the need is
  # "give me that card back", not a history of every edit.

  MAX_DELETED_CARDS = 10

  # Cards present in `before` but gone from `after`, newest first, capped.
  # Matched on cid — the stable per-card id — so a reorder is never mistaken for
  # a delete, which comparing by index would do constantly.
  def self.record_deleted_cards(before, after, existing)
    remaining = Array(after).filter_map { |c| c["cid"].to_s.presence if c.is_a?(Hash) }.to_set

    # Anything back in the deck leaves the bin — evaluated on EVERY save, not
    # only ones that also delete something, because a restore is precisely the
    # save that removes nothing.
    kept = Array(existing).reject { |e| e.is_a?(Hash) && remaining.include?(e.dig("card", "cid").to_s) }

    removed = Array(before).select do |c|
      c.is_a?(Hash) && c["cid"].to_s.present? && !remaining.include?(c["cid"].to_s)
    end
    return kept.first(MAX_DELETED_CARDS) if removed.empty?

    entries = removed.map { |card| { "card" => card, "deleted_at" => Time.current.iso8601 } }
    (entries + kept).first(MAX_DELETED_CARDS)
  end

  # The bin, newest first, with anything malformed dropped.
  def recently_deleted_cards
    Array(read_attribute(:deleted_cards)).select do |entry|
      entry.is_a?(Hash) && entry["card"].is_a?(Hash) && entry.dig("card", "cid").present?
    end
  end

  # Pull one card back out by cid. Returns the card hash, or nil if it's gone.
  # Removing it from the bin is the caller's business — restoring is a client-side
  # splice, and the card only truly returns once the deck is saved with it.
  def deleted_card(cid)
    recently_deleted_cards.find { |e| e.dig("card", "cid").to_s == cid.to_s }&.dig("card")
  end

  # ── Free-text limits ───────────────────────────────────────────────────────

  # The free-text cap for the card at `index`.
  def free_text_limit_at(index)
    card = Array(cards)[index.to_i]
    return DEFAULT_FREE_TEXT_LIMIT unless card.is_a?(Hash)

    limit = card["char_limit"].to_i
    limit.positive? ? limit.clamp(FREE_TEXT_LIMIT_RANGE.min, FREE_TEXT_LIMIT_RANGE.max) : DEFAULT_FREE_TEXT_LIMIT
  end

  # Truncate every free-text answer to its card's limit.
  #
  # The client has a maxlength now, but a maxlength is a courtesy: this endpoint
  # is public and takes JSON, so anything relying on the browser to keep the
  # answers column bounded isn't a limit at all. Applies to the answer value and
  # to the "Other" box, which is free text by another name.
  def clamp_free_text(answers)
    return answers unless answers.is_a?(Hash)

    answers.each_with_object({}) do |(key, entry), out|
      unless entry.is_a?(Hash)
        out[key] = entry
        next
      end

      limit = free_text_limit_at(key)
      clamped = entry.dup
      clamped["value"] = entry["value"].first(limit) if entry["value"].is_a?(String)
      clamped["other"] = entry["other"].first(limit) if entry["other"].is_a?(String)
      out[key] = clamped
    end
  end

  # The contact card's answer shape: an object of these fields (any subset).
  # 120 chars is generous for a name/company/industry and stops the public
  # JSON endpoint being used to stuff paragraphs into a lead field.
  CONTACT_FIELDS      = %w[name company industry email].freeze
  CONTACT_FIELD_LIMIT = 120

  # Bound and validate contact-card answers. Same posture as clamp_free_text
  # directly above the call site: the client validates as a courtesy, but the
  # endpoint is public JSON, so the server owns the contract — only the four
  # known fields survive, each stripped and clamped, and an email that isn't
  # one is dropped rather than stored malformed.
  def clamp_contact_entries(answers)
    return answers unless answers.is_a?(Hash)

    contact_keys = Array(cards).each_with_index
                               .select { |card, _| card.is_a?(Hash) && card["type"].to_s == "contact_form" }
                               .map { |_, idx| idx.to_s }
    return answers if contact_keys.empty?

    answers.each_with_object({}) do |(key, entry), out|
      unless contact_keys.include?(key) && entry.is_a?(Hash)
        out[key] = entry
        next
      end

      clamped = entry.dup
      value = entry["value"]
      if value.is_a?(Hash)
        cleaned = CONTACT_FIELDS.each_with_object({}) do |field, acc|
          v = (value[field] || value[field.to_sym]).to_s.strip.first(CONTACT_FIELD_LIMIT)
          acc[field] = v if v.present?
        end
        cleaned.delete("email") unless cleaned["email"]&.match?(URI::MailTo::EMAIL_REGEXP)
        clamped["value"] = cleaned.presence
      else
        # A contact answer is an object or nothing — scalars are junk.
        clamped["value"] = nil
      end
      out[key] = clamped
    end
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
      # Carried with the deck, not left behind: dup_cards copies any tailored
      # Heritage card's heritage_country along with it, so a copy that forgot
      # the setting would claim a country's taxonomy while saying it has none.
      audience_country:        audience_country,
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
      # Identical creator content means identical SDG tags — copying is free,
      # re-deriving would spend a Claude call to compute the same answer.
      sdgs:                    read_attribute(:sdgs),
      compare_note:            compare_note,
      thankyou_title:          thankyou_title,
      thankyou_body:           thankyou_body,
      forward_url:             forward_url,
      forward_label:           forward_label,
      consent_text:            consent_text,
      consent_image:           consent_image,
      consent_image_credit:    consent_image_credit,
      consent_image_credit_url: consent_image_credit_url,
      leaderboard_enabled:     leaderboard_enabled,
      leaderboard_retake_policy: leaderboard_retake_policy
    ).tap { |copy| copy_card_attachments_to(copy) }
  end

  # Blobs a card's JSON points at — uploaded stills and stored Lottie
  # animations — belong to the survey they were attached to. The cards JSON is
  # copied verbatim above, so without this the copy's media is served entirely
  # out of the ORIGINAL's attachments: the paths resolve, nothing looks wrong,
  # and the copy silently depends on a survey it has no relationship with.
  # Re-attaching the same blobs gives the copy its own claim on them (Active
  # Storage keeps one blob, two attachments), so neither survey can pull the
  # media out from under the other.
  def copy_card_attachments_to(copy)
    referenced = card_images.blobs.select do |blob|
      copy.cards.to_json.include?(blob.filename.to_s)
    end
    copy.card_images.attach(referenced) if referenced.any?
  rescue StandardError => e
    # A copy without its attachments still works today (the paths point at the
    # original's blobs), so this is a hardening step, not a precondition.
    ErrorReporting.report("Survey#copy_card_attachments_to", e, survey_id: id)
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

  # ── What a respondent is offered after they finish ────────────────────────
  # SurveyLink answers these same three questions, overriding them per link
  # (see SurveyLink#compare_results?). Anything rendering the player asks
  # whichever object it arrived through — `(@survey_link || @survey)` — so the
  # player never has to know whether a share link is in play. They exist as
  # aliases rather than the columns themselves so a link's own nil-means-inherit
  # column reader stays readable for the settings form.
  def compare_results? = show_results_comparison?
  def share_button?    = share_enabled?
  def regions_map?     = regions_enabled?

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

  # UN SDG tags, derived by SdgClassifier at import/seed time (see UnSdgs).
  # Always an array; empty means "no goal clearly applies", not "untagged".
  def sdgs
    Array(read_attribute(:sdgs))
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

  # ── Consent ────────────────────────────────────────────────────────────────
  # Two shapes, one respondent-facing promise. The survey-level gate
  # (consent_text) is a single pseudo-card pinned before the welcome card; a
  # consent_gate CARD is an ordinary deck card that can span several pages and
  # be reordered. A Verto uses one or the other — never both, or a respondent
  # would be asked to agree twice.

  # The multi-page consent card, if the deck has one.
  def consent_gate_card
    Array(cards).find { |c| c.is_a?(Hash) && c["type"].to_s == "consent_gate" }
  end

  def consent_gate_card?
    consent_gate_card.present?
  end

  # The survey-level gate. False once a consent card is in the deck, so the
  # pseudo-card stops rendering rather than stacking a second gate in front of
  # the first — the card wins, being the more specific thing the creator built.
  def consent_required?
    consent_text.present? && !consent_gate_card?
  end

  # Whether this Verto asks a respondent for personal data. DemographicQuestions
  # appends birth month/year, location and gender to every Verto at creation, so
  # in practice this is true almost everywhere — which is exactly why consent
  # being optional was a compliance hole rather than an edge case (P0-6).
  def collects_personal_data?
    Array(cards).any? { |c| c.is_a?(Hash) && c["demographic"] }
  end

  # True when personal data is collected and the creator built no gate of either
  # kind. The player supplies a default gate in that case rather than letting the
  # collection happen ungated.
  #
  # Enforced at the player and not at publish, deliberately: a publish-time
  # requirement would leave every ALREADY-live Verto collecting birth dates and
  # locations with no gate at all, which is the actual exposure. This closes it
  # for those too, at the cost of respondents on a live Verto meeting a consent
  # screen they didn't see yesterday.
  def default_consent_gate?
    collects_personal_data? && consent_text.blank? && !consent_gate_card?
  end

  # Whether the player renders the survey-level pseudo-card before the deck,
  # from either the creator's own consent_text or the default above.
  def show_consent_gate?
    consent_required? || default_consent_gate?
  end

  # The wording the survey-level gate actually shows.
  def effective_consent_text
    return consent_text if consent_text.present?

    I18n.t("player.consent_default_text") if default_consent_gate?
  end

  # Whether a respondent has to agree before answering, by any route.
  def consent_gated?
    consent_required? || consent_gate_card? || default_consent_gate?
  end

  # What a response records as the text the respondent actually agreed to. For a
  # card gate that's its pages joined in order, so the snapshot stays a faithful
  # record of what was on screen even if the card is edited later. For the
  # default gate it's the default wording, so the audit trail records what the
  # respondent was actually shown rather than a blank.
  def consent_snapshot_text
    card = consent_gate_card
    return effective_consent_text if card.nil?

    Array(card["pages"]).filter_map { |p| p["text"].presence if p.is_a?(Hash) }.join("\n\n").presence
  end

  # How the player presents this Verto. "cards" is the default immersive,
  # animated experience; "form" keeps the same one-question-at-a-time flow but
  # strips the swipe gestures and game-like animation so it reads as a plain
  # questionnaire (see the .forms-mode CSS layer and the player root class).
  RENDER_MODES = %w[cards form].freeze

  def self.normalize_render_mode(value)
    RENDER_MODES.include?(value.to_s) ? value.to_s : "cards"
  end

  # The audience's country as an ISO 3166-1 alpha-2 code, or nil for "not set".
  # Allowlist-or-nil against WorldRegions rather than a CHECK constraint: the
  # value set is 249 rows that already live in Ruby, and "not set" is a normal
  # state rather than an error, so an unknown code degrades to the global
  # heritage taxonomy instead of failing a save.
  def self.normalize_audience_country(value)
    code = value.to_s.strip.upcase.presence
    code if code && WorldRegions.valid?(code)
  end

  # Belt-and-braces behind normalize_audience_country: the column has no CHECK
  # (249 ISO codes is not a readable constraint, and region_country — same
  # registry, same shape — has none either), so the model is where a bad code
  # has to surface. allow_nil because "no country" is a real state, not a gap.
  validates :audience_country, inclusion: { in: WorldRegions::COUNTRIES.keys }, allow_nil: true

  def audience_country_name
    WorldRegions.name_for(audience_country) if audience_country.present?
  end

  def forms_mode?
    render_mode == "form"
  end

  # What a retake does to a player's leaderboard score. A string enum per the
  # render_mode precedent, normalized on write (update_settings) and CHECK-
  # constrained in the database, so an unknown value can't arrive silently.
  #
  #   accumulate — retakes add to the total (the default: the most game-like
  #                reading of "play again", and the least surprising).
  #   no_redo    — one play each; the player skips a recognised returner
  #                straight to the board, and aggregation ignores stray extras.
  #   restart    — a retake wipes the old score and starts over.
  LEADERBOARD_RETAKE_POLICIES = %w[accumulate no_redo restart].freeze

  # The column carries a database CHECK (P2-8), and the coverage rule in
  # enum_constraints_test is that a constrained column also declares its values
  # in the model — a bad value should surface as a validation error, not a raw
  # database exception.
  validates :leaderboard_retake_policy, inclusion: { in: LEADERBOARD_RETAKE_POLICIES }

  def self.normalize_leaderboard_retake_policy(value)
    LEADERBOARD_RETAKE_POLICIES.include?(value.to_s) ? value.to_s : "accumulate"
  end

  # The board only ranks token totals, so without tokenisation there is
  # nothing to rank — leaderboard_enabled alone is inert (the flag survives a
  # pre-live tokenisation switch-off, but nothing renders or records).
  def leaderboard_active?
    tokenisation_enabled? && leaderboard_enabled?
  end

  def leaderboard_no_redo?
    leaderboard_retake_policy == "no_redo"
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
  # namespace — a Verto's slug or publish_token, a partner share token, or a
  # share link's slug — so nothing a creator chooses can make
  # PlayerController#load_survey_and_share resolve ambiguously. Each excluding_
  # argument spares the record doing the asking from colliding with itself.
  def self.play_key_taken?(value, excluding_survey_id: nil, excluding_link_id: nil)
    return false if value.blank?
    Survey.where.not(id: excluding_survey_id).exists?(slug: value) ||
      Survey.where.not(id: excluding_survey_id).exists?(publish_token: value) ||
      SurveyShare.exists?(share_token: value) ||
      SurveyLink.where.not(id: excluding_link_id).exists?(slug: value)
  end

  # The Verto's own custom-link form asks the same question about itself.
  def self.slug_taken?(value, excluding_id: nil)
    play_key_taken?(value, excluding_survey_id: excluding_id)
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
    self.cards = self.class.normalize_range_cards!(
      cards, fill: self.class.localized_range_labels(default_locale)
    )
  end

  def hoist_option_label_emoji
    self.cards = self.class.hoist_option_label_emoji!(cards)
  end

  # Move an option label's leading/trailing emoji into that option's icon tile,
  # by promoting it to `option_styles[i]["emoji"]` — the slot every render path
  # (option_tile_icon, choice_templates.js, both repaint paths) already draws
  # inside the tile. Generated decks routinely write "🎯 Pay off debt", which
  # showed the emoji beside the words while the tile keyword-matched a
  # different icon entirely.
  #
  # Doing it here rather than at render time is what keeps it simple: once the
  # emoji IS an option style, nothing downstream needs to know — it renders,
  # serializes and round-trips like any 🎨-picked icon, and a creator can change
  # or clear it the same way.
  #
  # An option label is an ANSWER KEY (`correct`, `tokens` and logic
  # `match.value` all reference it by string), so:
  #   • published Vertos are skipped entirely — their labels are the key for
  #     responses already collected, exactly the reasoning enforce_range_scale
  #     documents above;
  #   • every label-keyed field on the card is rewritten in the same pass;
  #   • an option that already carries an explicit icon or emoji is left ALONE,
  #     label included. That pick wins the tile, so hoisting would mean deleting
  #     an emoji with nowhere to put it — and it makes the transform converge
  #     after one pass instead of nibbling a second emoji off on the next save.
  def self.hoist_option_label_emoji!(list)
    Array(list).map do |card|
      next card unless card.is_a?(Hash) && OPTION_STYLE_TYPES.include?(card["type"].to_s)

      options = Array(card["options"])
      next card if options.empty?

      options = options.dup
      styles  = Array(card["option_styles"]).dup
      html    = Array(card["options_html"]).dup
      renamed = {}

      options.each_with_index do |label, i|
        style = styles[i].is_a?(Hash) ? styles[i] : nil
        next if style && (style["icon"].to_s.present? || style["emoji"].to_s.present?)

        glyphs, text = LabelEmoji.split(label)
        next unless glyphs && text.present? && text != label.to_s

        options[i] = text
        renamed[label.to_s] = text
        styles[i] = (style || {}).merge("emoji" => glyphs.first(MAX_TOKEN_ICON))
        # Keep the rich-text twin in step, or Survey#sanitize's equivalence
        # check drops the whole formatting layer for this option.
        html[i] = html[i].sub(glyphs, "") if html[i].is_a?(String) && html[i].include?(glyphs)
      end

      next card if renamed.empty?

      out = card.merge("options" => options, "option_styles" => styles)
      out["options_html"] = html if card.key?("options_html")
      rename_option_key_references!(out, renamed)
      out
    end
  end

  # The three places a card refers to an option BY ITS LABEL. Missing one would
  # silently unset a quiz answer, strand a branch, or drop a token award.
  def self.rename_option_key_references!(card, renamed)
    case card["correct"]
    when String then card["correct"] = renamed.fetch(card["correct"], card["correct"])
    when Array  then card["correct"] = card["correct"].map { |v| v.is_a?(String) ? renamed.fetch(v, v) : v }
    end

    if card["tokens"].is_a?(Hash)
      card["tokens"] = card["tokens"].transform_keys { |k| renamed.fetch(k.to_s, k) }
    end

    if card["logic"].is_a?(Hash)
      Array(card["logic"]["routes"]).each do |route|
        match = route.is_a?(Hash) ? route["match"] : nil
        next unless match.is_a?(Hash) && match["value"].is_a?(String)
        match["value"] = renamed.fetch(match["value"], match["value"])
      end
    end
    card
  end

  # Replace any inline base64 image about to be written with a stored blob path.
  #
  # Deliberately forgiving: a conversion that fails leaves the data-URL alone,
  # exactly as the upload path and the backfill already do. A fat image beats a
  # broken one, and this must never be the reason a creator's save is refused.
  # Only the attributes actually being written, so an unrelated save never walks
  # a whole deck looking for images.
  def externalize_inline_images
    attributes = []
    attributes << :cards if will_save_change_to_cards?
    attributes += %i[background_image consent_image].select { |a| will_save_change_to_attribute?(a) }
    externalize_images_in(attributes)
  end

  # On create there's no id yet, so a blob can't be attached and the data-URL
  # rides through. Converting straight after means the base64 is in the column
  # for one write rather than indefinitely — the create path is the rare one
  # (a duplicate of a not-yet-converted deck), so paying an extra UPDATE there
  # is the right trade for never having to special-case it elsewhere.
  def externalize_inline_images_after_create
    updates = externalize_images_in(%i[cards background_image consent_image])
    update_columns(updates) if updates.any?
  end

  # Converts in place and returns { attribute => new_value } for whatever moved.
  def externalize_images_in(attributes)
    updates = {}

    if attributes.include?(:cards)
      converted = externalized_cards
      if converted
        self.cards = converted
        updates[:cards] = converted
      end
    end

    (attributes & %i[background_image consent_image]).each do |attribute|
      path = externalized_image_path(read_attribute(attribute))
      next unless path

      write_attribute(attribute, path)
      updates[attribute] = path
    end

    updates
  end

  # The deck with every inline image replaced by a stored path, or nil when
  # there was nothing to convert.
  def externalized_cards
    touched = false

    converted = Array(cards).map do |card|
      next card unless card.is_a?(Hash)

      c = card
      if (path = externalized_image_path(c["image"]))
        c = c.merge("image" => path)
        touched = true
      end

      images = Array(c["option_images"])
      if images.any? { |value| Survey::CardImageStore.data_url?(value) }
        c = c.merge("option_images" => images.map { |value| externalized_image_path(value) || value })
        touched = true
      end

      c
    end

    touched ? converted : nil
  end

  # The stored path for an inline image, or nil when there's nothing to do (it's
  # already a path, blank, or the conversion failed).
  def externalized_image_path(value)
    return nil unless Survey::CardImageStore.data_url?(value)

    # A blob has to belong to a persisted record. On create the row doesn't exist
    # yet, so the data-URL rides through this save and is converted on the next
    # one — or by the backfill task, whichever comes first.
    return nil unless persisted?

    blob = Survey::CardImageStore.attach(self, value)
    return nil unless blob

    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
  rescue => e
    ErrorReporting.report("Survey#externalize_inline_images", e, survey_id: id)
    nil
  end

  # Per-survey HMAC key, from Rails' own key generator — tied to
  # secret_key_base, so it needs no column of its own and rotating the secret
  # invalidates every digest at once (which is the correct behaviour: they were
  # only ever comparable to each other).
  def respondent_code_key
    Rails.application.key_generator.generate_key("respondent_code/survey/#{id}", 32)
  end

  def player_key_hmac_key
    Rails.application.key_generator.generate_key("player_key/survey/#{id}", 32)
  end
end
