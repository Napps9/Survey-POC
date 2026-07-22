class Portfolio < ApplicationRecord
  belongs_to :funder
  has_many :portfolio_memberships, dependent: :destroy
  has_many :funder_memberships, through: :portfolio_memberships
  has_many :member_organisations, through: :funder_memberships, source: :organisation
  has_many :portfolio_common_question_sets, dependent: :destroy
  has_many :common_question_sets, through: :portfolio_common_question_sets

  scope :kept,     -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

  validates :name, presence: true, length: { maximum: 80 },
                   uniqueness: { scope: :funder_id, case_sensitive: false }

  # Members whose underlying license is currently active — the funder's read
  # path (and the auto-population sync) must use this, never the raw
  # association, so a suspended grantee immediately drops out of both.
  def active_memberships
    portfolio_memberships.joins(:funder_membership).merge(FunderMembership.active)
  end

  def archive!
    update!(deleted_at: Time.current)
  end
end
