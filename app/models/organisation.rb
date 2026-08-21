class Organisation < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :surveys, dependent: :destroy
  has_many :verto_builds, dependent: :destroy
  has_many :invites, dependent: :destroy

  # Ask Verto. corpus_entries are the account's offers of its own Vertos to the
  # shared corpus; ask_threads are its conversations with it. Both go when the
  # account does — deleting an organisation must take its consent record with it,
  # not leave an orphan pointing at a deleted survey.
  has_many :corpus_entries, dependent: :destroy
  has_many :ask_threads, dependent: :destroy

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

  # A second logo, for LIGHT surfaces. Named for the surface it goes ON rather
  # than for its own colour, because "logo_light" reads both ways and the wrong
  # reading picks the invisible one: a light logo is what you use on a DARK
  # background. Everything the platform draws is dark chrome — the masthead,
  # the thank-you card, the editor, settings — except one thing, and it is the
  # first thing a respondent ever sees: the welcome card's logo sits on the
  # white answer panel. An account whose only mark is a white wordmark (the
  # normal case, since the rest of the platform is dark) had it disappear
  # there. Optional; brand_logo_tag falls back to :logo, so an account that
  # uploads one logo behaves exactly as it did.
  has_one_attached :logo_on_light

  # The organisation's own brand-asset library — images the org uploads once and
  # can then drop onto any card/background from the editor's media picker, the
  # same way the shared Verto Library works but scoped to this account only.
  #
  # The :thumb variant is what the library tiles render, and it is PREPROCESSED
  # on purpose. Declared lazily, a library of 60 assets means 60 representation
  # requests on first view, each spawning a libvips transform on a Puma request
  # thread — a burst of native memory on a 512MB instance with three threads,
  # which is exactly the shape that trips the memory watchdog. Preprocessing
  # moves each transform to a job at upload time, so viewing the library is a
  # redirect to an already-built blob and costs nothing.
  #
  # 400px because as_thumb_path's tiles are rendered at 96px: enough for a 2x
  # display and for the larger media-picker tiles, without storing near-originals.
  ASSET_THUMB_LIMIT = 400

  has_many_attached :assets do |attachable|
    attachable.variant :thumb, resize_to_limit: [ ASSET_THUMB_LIMIT, ASSET_THUMB_LIMIT ],
                               preprocessed: true
  end

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
