class Organisation < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :surveys, dependent: :destroy
  has_many :verto_builds, dependent: :destroy
  has_many :invites, dependent: :destroy

  has_many :partnerships, dependent: :destroy
  has_many :partnership_memberships, dependent: :destroy
  has_many :member_partnerships, through: :partnership_memberships, source: :partnership

  has_many :funders, dependent: :destroy
  has_many :funder_memberships, dependent: :destroy
  has_many :member_funders, through: :funder_memberships, source: :funder
  has_many :portfolio_memberships, through: :funder_memberships
  has_many :portfolios, through: :portfolio_memberships

  has_many :common_question_sets, dependent: :destroy

  has_one_attached :logo

  # The organisation's own brand-asset library — images the org uploads once and
  # can then drop onto any card/background from the editor's media picker, the
  # same way the shared Verto Library works but scoped to this account only.
  has_many_attached :assets

  LOGO_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp image/svg+xml].freeze
  LOGO_MAX_BYTES     = 2.megabytes

  # Brand assets share the logo's image allow-list; capped a little larger per
  # file (brand photography, not just a wordmark) and bounded in count so an
  # account can't grow the library without limit.
  ASSET_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp image/svg+xml].freeze
  ASSET_MAX_BYTES     = 5.megabytes
  MAX_ASSETS          = 60

  validate :logo_must_be_a_supported_image
  validate :assets_must_be_supported_images

  # Freshest-first so the management grid and the picker show the most recently
  # uploaded assets at the top.
  def ordered_assets
    assets.attachments.includes(:blob).order(created_at: :desc)
  end

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

  # Same shape as the logo guard, applied to every attached brand asset: only
  # supported image types, each under the per-file cap, and no more than
  # MAX_ASSETS in the library. Keeps junk/oversized files out of storage and
  # the account's library bounded.
  def assets_must_be_supported_images
    return unless assets.attached?

    if assets.attachments.size > MAX_ASSETS
      errors.add(:assets, "library is full — remove some before adding more (max #{MAX_ASSETS})")
    end
    assets.each do |asset|
      next unless asset.blob # newly attached blobs are present before save
      unless ASSET_CONTENT_TYPES.include?(asset.blob.content_type)
        errors.add(:assets, "must be PNG, JPEG, GIF, WebP or SVG images")
        break
      end
      if asset.blob.byte_size > ASSET_MAX_BYTES
        errors.add(:assets, "must each be smaller than #{ASSET_MAX_BYTES / 1.megabyte} MB")
        break
      end
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
