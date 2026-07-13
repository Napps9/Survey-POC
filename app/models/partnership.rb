class Partnership < ApplicationRecord
  belongs_to :organisation
  has_many :partnership_memberships, dependent: :destroy
  has_many :member_organisations, through: :partnership_memberships, source: :organisation
  has_many :partnership_vertos, dependent: :destroy
  has_many :surveys, through: :partnership_vertos
  has_many :survey_shares, through: :partnership_vertos
  has_many :partnership_common_question_sets, dependent: :destroy
  has_many :common_question_sets, through: :partnership_common_question_sets
  has_many :invites, dependent: :nullify

  enum :status, { active: "active", pending: "pending", revoked: "revoked" }

  validates :name, presence: true, length: { maximum: 80 },
                   uniqueness: { scope: :organisation_id, case_sensitive: false }

  def active_memberships
    partnership_memberships.active
  end
end
