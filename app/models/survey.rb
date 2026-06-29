class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy
  has_many :survey_region_links, dependent: :destroy
  has_many :alliance_vertos, dependent: :destroy

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
      c["image"] = sanitize_image_url(c["image"]) if c.key?("image")
      if c.key?("option_images")
        c["option_images"] = Array(c["option_images"]).map { |u| sanitize_image_url(u) }
      end

      if c.key?("image_credit") || c.key?("image_credit_url")
        if c["image"].present?
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

  def archive!
    update!(deleted_at: Time.current)
  end

  def published?
    publish_token.present?
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

  # When set, respondents must agree to this text before the first card.
  def consent_required?
    consent_text.present?
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
