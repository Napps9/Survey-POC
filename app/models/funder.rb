class Funder < ApplicationRecord
  belongs_to :organisation
  has_many :funder_memberships, dependent: :destroy
  has_many :member_organisations, through: :funder_memberships, source: :organisation
  has_many :invites, dependent: :nullify
  has_many :portfolios, dependent: :destroy

  enum :status, { active: "active", revoked: "revoked" }

  validates :name, presence: true, length: { maximum: 80 },
                   uniqueness: { scope: :organisation_id, case_sensitive: false }
  validates :seat_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def active_memberships
    funder_memberships.active
  end

  # Seats held by active licenses plus outstanding join links/invites — counting
  # pending invites here stops an admin generating more invites than they have
  # seats for, without needing a separate reservation record.
  def seats_used
    funder_memberships.active.count + invites.pending.count
  end

  def seats_available
    seat_count - seats_used
  end

  def seats_available?
    seats_available.positive?
  end
end
