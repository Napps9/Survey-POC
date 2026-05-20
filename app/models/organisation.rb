class Organisation < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :surveys, dependent: :destroy
  has_many :invites, dependent: :destroy

  has_many :alliances, dependent: :destroy
  has_many :partner_organisations, through: :alliances
  has_many :alliance_memberships,
           class_name: "Alliance",
           foreign_key: :partner_organisation_id,
           dependent: :destroy,
           inverse_of: :partner_organisation
  has_many :parent_organisations, through: :alliance_memberships, source: :organisation

  has_one_attached :logo

  enum :kind, { creator: "creator", partner: "partner" }

  # The company's default Verto palette — pre-fills each new Verto's colour
  # step. Falls back to the Playverto default when never set.
  def brand_palette
    read_attribute(:default_brand_palette).presence || BrandPalette::DEFAULT
  end

  def self.generate_unique_slug(name)
    base = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
    base = "org" if base.blank?
    slug = base
    slug = "#{base}-#{SecureRandom.hex(3)}" while Organisation.exists?(slug: slug)
    slug
  end
end
