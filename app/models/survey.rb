class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy
  has_many :alliance_vertos, dependent: :destroy

  scope :recent,   -> { order(updated_at: :desc) }
  scope :kept,     -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

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

  def self.sanitize_background_image(value)
    v = value.to_s.strip
    return nil if v.blank?
    (v.match?(DATA_IMAGE_URL) || v.match?(ASSET_IMAGE_URL)) ? v : nil
  end

  def archive!
    update!(deleted_at: Time.current)
  end

  def published?
    publish_token.present?
  end

  # A "responder" is anyone who answered at least one question (not just those
  # who submitted). Reads the preloaded :responses association in Ruby so the
  # dashboard's includes(:responses) avoids per-card queries.
  def responders
    responses.to_a.select do |r|
      r.answers.is_a?(Hash) && r.answers.values.any? { |a| a.is_a?(Hash) && a["value"].present? }
    end
  end

  def responders_count
    responders.size
  end

  # Of the responders, the percentage who completed (submitted) the Verto.
  # nil when there are no responders yet.
  def completion_rate
    rs = responders
    return nil if rs.empty?
    (rs.count { |r| r.status == "completed" } * 100.0 / rs.size).round
  end
end
