class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy
  has_many :partnership_vertos, dependent: :destroy

  scope :recent,   -> { order(updated_at: :desc) }
  scope :kept,     -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

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
        "options"     => Array(t["options"])
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
  # Pexels CDN URLs (host-whitelisted) so editor-picked and auto-populated
  # stock photos survive the sanitizer. No quotes/parens, so it stays safe to
  # interpolate into an inline `url('…')` style.
  PEXELS_IMAGE_URL = %r{\Ahttps://images\.pexels\.com/[\w\-./]+\.(?:png|jpe?g|webp)(?:\?[\w%\-=&.+]*)?\z}i
  # Photographer-credit link target: a pexels.com page (the photographer's
  # profile). Doubles as the "link back to Pexels" the API guidelines ask for.
  PEXELS_CREDIT_URL = %r{\Ahttps://(?:www\.)?pexels\.com/[\w@\-./?=&%]*\z}i
  MAX_CREDIT_NAME   = 80
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

  # A single image value (background, card image, or one option_image): an
  # uploaded data-URL (size-capped), an app-rooted asset path, or a Pexels CDN
  # URL — anything else (or blank) returns nil.
  def self.sanitize_image_url(value)
    v = value.to_s.strip
    return nil if v.blank?
    return v if v.match?(ASSET_IMAGE_URL)
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
  def self.sanitize_cards_images!(cards)
    Array(cards).map do |card|
      next card unless card.is_a?(Hash)
      c = card.dup
      # Every card carries a stable opaque id so answer-branching can target it
      # by cid (not array index). The editor serialiser sends one; this is the
      # backstop for AI/import/hand-crafted cards that arrive without one.
      c["cid"] = c["cid"].to_s.strip.presence || "c_#{SecureRandom.hex(3)}"
      c.delete("logic") unless c["logic"].is_a?(Hash) # drop malformed logic blocks
      c["image"] = sanitize_image_url(c["image"]) if c.key?("image")
      if c.key?("option_images")
        c["option_images"] = Array(c["option_images"]).map { |u| sanitize_image_url(u) }
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

  def published?
    publish_token.present?
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
    organisation.surveys.create!(
      title:                   self.class.append_copy_suffix(title),
      description:             description,
      theme:                   self.class.append_copy_suffix(theme),
      audience_age:            audience_age,
      key_insight:             key_insight,
      cards:                   self.class.remap_card_logic!(JSON.parse(cards.to_json)),
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
      consent_text:            consent_text
    )
  end

  # Give every card a fresh cid and rewrite each branching target (route +
  # default) from the old cid to the new one, so a duplicated deck's routes
  # stay internally consistent. Targets whose old cid isn't in the deck (an
  # unexpected dangling route) are left as-is; the player fails them safe to
  # the linear next card. Mutates and returns `cards`.
  def self.remap_card_logic!(cards)
    cards  = Array(cards)
    id_map = {}
    cards.each do |card|
      next unless card.is_a?(Hash)
      old   = card["cid"].to_s
      fresh = "c_#{SecureRandom.hex(3)}"
      id_map[old] = fresh if old.present?
      card["cid"] = fresh
    end
    cards.each do |card|
      next unless card.is_a?(Hash) && card["logic"].is_a?(Hash)
      logic = card["logic"]
      Array(logic["routes"]).each { |route| remap_logic_target!(route["to"], id_map) if route.is_a?(Hash) }
      remap_logic_target!(logic["default"], id_map)
    end
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
      "forward_label" => nil
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
end
