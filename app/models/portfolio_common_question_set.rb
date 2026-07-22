class PortfolioCommonQuestionSet < ApplicationRecord
  belongs_to :portfolio
  belongs_to :common_question_set

  validates :common_question_set_id, uniqueness: { scope: :portfolio_id }
  validate :set_owned_by_funders_organisation

  private

  # A funder can only bank-share question sets it created itself — mirrors how
  # PartnershipCommonQuestionSetsController#create scopes the lookup to
  # current_organisation.common_question_sets; this is the model-level guard
  # behind that controller-level restriction.
  def set_owned_by_funders_organisation
    return unless portfolio && common_question_set
    return if common_question_set.organisation_id == portfolio.funder.organisation_id
    errors.add(:common_question_set, "must belong to the funder's own organisation")
  end
end
