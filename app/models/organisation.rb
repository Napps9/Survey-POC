class Organisation < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :surveys, dependent: :destroy
  has_many :invites, dependent: :destroy

  has_many :alliances, dependent: :destroy
  has_many :alliance_memberships, dependent: :destroy
  has_many :member_alliances, through: :alliance_memberships, source: :alliance

  has_many :common_question_sets, dependent: :destroy

  has_one_attached :logo

  LOGO_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp image/svg+xml].freeze
  LOGO_MAX_BYTES     = 2.megabytes

  validate :logo_must_be_a_supported_image

  # The company's default Verto palette — pre-fills each new Verto's colour
  # step. Falls back to the Playverto default when never set.
  def brand_palette
    read_attribute(:default_brand_palette).presence || BrandPalette::DEFAULT
  end

  # Reject logo uploads that aren't a reasonably-sized image. Keeps junk/oversized
  # files (and surprising content types) out of storage; the controller surfaces
  # the error. Active Storage already serves SVGs as a download rather than inline.
  def logo_must_be_a_supported_image
    return unless logo.attached?

    unless LOGO_CONTENT_TYPES.include?(logo.blob.content_type)
      errors.add(:logo, "must be a PNG, JPEG, GIF, WebP or SVG image")
    end
    if logo.blob.byte_size > LOGO_MAX_BYTES
      errors.add(:logo, "must be smaller than 2 MB")
    end
  end

  def self.generate_unique_slug(name)
    base = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
    base = "org" if base.blank?
    slug = base
    slug = "#{base}-#{SecureRandom.hex(3)}" while Organisation.exists?(slug: slug)
    slug
  end
end
