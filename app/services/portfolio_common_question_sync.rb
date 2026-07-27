# Splices a portfolio's mandatory Common Questions into each licensed
# grantee org's Vertos, mirroring PartnershipShareSync's idempotent "ensure"
# style but for auto-populated cards rather than shared-Verto rows.
class PortfolioCommonQuestionSync
  # Every CommonQuestion currently mandatory for `organisation` — the union of
  # every kept CommonQuestionSet attached to any Portfolio the org is an
  # ACTIVE member of, across every funder licensing it.
  def self.mandatory_common_questions_for(organisation)
    fm_ids = organisation.funder_memberships.active.pluck(:id)
    return CommonQuestion.none if fm_ids.empty?

    set_ids = PortfolioCommonQuestionSet
                .joins(portfolio: :portfolio_memberships)
                .where(portfolio_memberships: { funder_membership_id: fm_ids })
                .distinct
                .pluck(:common_question_set_id)
    return CommonQuestion.none if set_ids.empty?

    CommonQuestion.joins(:common_question_set)
                  .merge(CommonQuestionSet.kept)
                  .where(common_question_set_id: set_ids)
                  .order(:common_question_set_id, :position)
  end

  # Splices any mandatory question missing (matched on common_question_id)
  # onto the END of ONE Verto's cards. Append-only — never reorders/removes
  # existing cards, so already-collected Response#answers (keyed by index)
  # stay valid. Idempotent.
  def self.ensure_cards_for_survey(survey)
    mandatory = mandatory_common_questions_for(survey.organisation).to_a
    return if mandatory.empty?
    existing_ids = Array(survey.cards).filter_map { |c| c["common_question_id"] if c.is_a?(Hash) }
    missing = mandatory.reject { |cq| existing_ids.include?(cq.id) }
    return if missing.empty?
    # Normalise only the cards being appended. Survey#enforce_range_scale skips
    # published Vertos to protect answers already collected against their
    # scale, but these cards are brand new and hold no answers — so a mandatory
    # Range question defined with 4 (or no) options must still land as the
    # 5-point scale every other Range card is.
    added = Survey.normalize_range_cards!(missing.map(&:to_card))
    survey.update!(cards: Array(survey.cards) + added)
  end

  # Backfill every kept Verto an org owns — used when the org joins a
  # portfolio, or when a portfolio's set roster changes.
  def self.ensure_cards_for(organisation:)
    organisation.surveys.kept.find_each { |survey| ensure_cards_for_survey(survey) }
  end

  # Bulk variant across a portfolio's current active members.
  def self.ensure_cards_for_portfolio(portfolio)
    org_ids = portfolio.active_memberships.pluck("funder_memberships.organisation_id")
    Organisation.where(id: org_ids).find_each { |org| ensure_cards_for(organisation: org) }
  end
end
