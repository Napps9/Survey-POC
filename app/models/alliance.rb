class Alliance < ApplicationRecord
  belongs_to :organisation
  has_many :alliance_memberships, dependent: :destroy
  has_many :member_organisations, through: :alliance_memberships, source: :organisation
  has_many :alliance_vertos, dependent: :destroy
  has_many :surveys, through: :alliance_vertos
  has_many :survey_shares, through: :alliance_vertos
  has_many :invites, dependent: :nullify

  enum :status, { active: "active", pending: "pending", revoked: "revoked" }

  validates :name, presence: true, length: { maximum: 80 },
                   uniqueness: { scope: :organisation_id, case_sensitive: false }

  def active_memberships
    alliance_memberships.active
  end
end
