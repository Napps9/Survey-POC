class PortfolioMembership < ApplicationRecord
  belongs_to :portfolio
  belongs_to :funder_membership
  has_one :organisation, through: :funder_membership

  validates :funder_membership_id, uniqueness: { scope: :portfolio_id }
  validate :funder_membership_belongs_to_same_funder

  # Adds funder_membership's org to portfolio and backfills its existing
  # Vertos with any mandatory common questions already attached. Mirrors
  # PartnershipMembership.join! calling PartnershipShareSync.
  def self.join!(portfolio:, funder_membership:)
    membership = find_or_create_by!(portfolio: portfolio, funder_membership: funder_membership)
    PortfolioCommonQuestionSync.ensure_cards_for(organisation: funder_membership.organisation)
    membership
  end

  private

  def funder_membership_belongs_to_same_funder
    return unless portfolio && funder_membership
    return if funder_membership.funder_id == portfolio.funder_id
    errors.add(:funder_membership, "must be licensed under this portfolio's funder")
  end
end
