require "test_helper"

class PortfolioMembershipTest < ActiveSupport::TestCase
  def build_org(name)
    Organisation.create!(name: name, slug: "#{name.parameterize}-#{SecureRandom.hex(3)}")
  end

  def setup
    @funder_org = build_org("Funder Org")
    @funder = @funder_org.funders.create!(name: "Fund", seat_count: 5)
    @portfolio = @funder.portfolios.create!(name: "Climate")
    @grantee = build_org("Grantee")
    @fm = FunderMembership.assign!(funder: @funder, organisation: @grantee)
  end

  test "rejects a funder_membership belonging to a different funder" do
    other_funder_org = build_org("Other Funder Org")
    other_funder = other_funder_org.funders.create!(name: "Other Fund", seat_count: 5)
    other_grantee = build_org("Other Grantee")
    other_fm = FunderMembership.assign!(funder: other_funder, organisation: other_grantee)

    membership = PortfolioMembership.new(portfolio: @portfolio, funder_membership: other_fm)
    refute membership.valid?
    assert_includes membership.errors[:funder_membership], "must be licensed under this portfolio's funder"
  end

  test "uniqueness of funder_membership within a portfolio" do
    PortfolioMembership.create!(portfolio: @portfolio, funder_membership: @fm)
    dup = PortfolioMembership.new(portfolio: @portfolio, funder_membership: @fm)
    refute dup.valid?
  end

  test "the same org can join multiple portfolios under the same funder" do
    other_portfolio = @funder.portfolios.create!(name: "Education")
    PortfolioMembership.create!(portfolio: @portfolio, funder_membership: @fm)

    membership = PortfolioMembership.new(portfolio: other_portfolio, funder_membership: @fm)
    assert membership.valid?
  end

  test "join! creates the membership and backfills the org's existing Vertos" do
    set = @funder_org.common_question_sets.create!(name: "Core")
    q = set.common_questions.create!(text: "How confident?", card_type: "range")
    @portfolio.portfolio_common_question_sets.create!(common_question_set: set)

    survey = @grantee.surveys.create!(
      title: "Existing", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ]
    )

    PortfolioMembership.join!(portfolio: @portfolio, funder_membership: @fm)

    assert_includes survey.reload.cards.filter_map { |c| c["common_question_id"] }, q.id
  end
end
