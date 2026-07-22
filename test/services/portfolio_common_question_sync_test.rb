require "test_helper"

class PortfolioCommonQuestionSyncTest < ActiveSupport::TestCase
  def build_org(name)
    Organisation.create!(name: name, slug: "#{name.parameterize}-#{SecureRandom.hex(3)}")
  end

  def blank_survey(org, title)
    org.surveys.create!(
      title: title, theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ]
    )
  end

  def setup
    @funder_org = build_org("Funder Org")
    @funder = @funder_org.funders.create!(name: "Fund", seat_count: 5)
    @portfolio = @funder.portfolios.create!(name: "Climate")
    @grantee = build_org("Grantee")
    @fm = FunderMembership.assign!(funder: @funder, organisation: @grantee)
    @portfolio.portfolio_memberships.create!(funder_membership: @fm)

    @set = @funder_org.common_question_sets.create!(name: "Core")
    @q1 = @set.common_questions.create!(text: "Confidence?", card_type: "range")
    @q2 = @set.common_questions.create!(text: "Recommend?", card_type: "yes_no")
    @portfolio.portfolio_common_question_sets.create!(common_question_set: @set)
  end

  test "mandatory_common_questions_for aggregates across portfolios and funders, excluding suspended licenses" do
    other_funder_org = build_org("Other Funder Org")
    other_funder = other_funder_org.funders.create!(name: "Other Fund", seat_count: 5)
    other_portfolio = other_funder.portfolios.create!(name: "Education")
    other_fm = FunderMembership.assign!(funder: other_funder, organisation: @grantee)
    other_portfolio.portfolio_memberships.create!(funder_membership: other_fm)
    other_set = other_funder_org.common_question_sets.create!(name: "Other core")
    q3 = other_set.common_questions.create!(text: "Barriers?", card_type: "open_ended")
    other_portfolio.portfolio_common_question_sets.create!(common_question_set: other_set)

    ids = PortfolioCommonQuestionSync.mandatory_common_questions_for(@grantee).map(&:id)
    assert_equal [ @q1.id, @q2.id, q3.id ].sort, ids.sort

    @fm.suspend!
    ids_after_suspend = PortfolioCommonQuestionSync.mandatory_common_questions_for(@grantee).map(&:id)
    assert_equal [ q3.id ], ids_after_suspend
  end

  test "ensure_cards_for_survey is idempotent and append-only" do
    survey = blank_survey(@grantee, "S")

    PortfolioCommonQuestionSync.ensure_cards_for_survey(survey)
    survey.reload
    assert_equal 3, survey.cards.size # welcome + 2 mandatory
    ids_first = survey.cards.filter_map { |c| c["common_question_id"] }

    PortfolioCommonQuestionSync.ensure_cards_for_survey(survey)
    survey.reload
    assert_equal 3, survey.cards.size, "running again must not duplicate cards"
    assert_equal ids_first.sort, survey.cards.filter_map { |c| c["common_question_id"] }.sort
  end

  test "ensure_cards_for_portfolio backfills every active member, skipping suspended ones" do
    active_grantee = build_org("Active Grantee")
    suspended_grantee = build_org("Suspended Grantee")
    fm_active = FunderMembership.assign!(funder: @funder, organisation: active_grantee)
    fm_suspended = FunderMembership.assign!(funder: @funder, organisation: suspended_grantee)
    @portfolio.portfolio_memberships.create!(funder_membership: fm_active)
    @portfolio.portfolio_memberships.create!(funder_membership: fm_suspended)
    fm_suspended.suspend!

    survey_active = blank_survey(active_grantee, "A")
    survey_suspended = blank_survey(suspended_grantee, "B")

    PortfolioCommonQuestionSync.ensure_cards_for_portfolio(@portfolio)

    assert_includes survey_active.reload.cards.filter_map { |c| c["common_question_id"] }, @q1.id
    refute_includes survey_suspended.reload.cards.filter_map { |c| c["common_question_id"] }, @q1.id
  end
end
