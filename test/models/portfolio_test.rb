require "test_helper"

class PortfolioTest < ActiveSupport::TestCase
  def build_org(name)
    Organisation.create!(name: name, slug: "#{name.parameterize}-#{SecureRandom.hex(3)}")
  end

  test "requires a unique name per funder" do
    funder_org = build_org("Funder Org")
    funder = funder_org.funders.create!(name: "Fund", seat_count: 5)
    funder.portfolios.create!(name: "Climate")

    dup = funder.portfolios.new(name: "Climate")
    refute dup.valid?
  end

  test "the same name is allowed under a different funder" do
    funder_org_a = build_org("Funder A")
    funder_org_b = build_org("Funder B")
    funder_a = funder_org_a.funders.create!(name: "Fund A", seat_count: 5)
    funder_b = funder_org_b.funders.create!(name: "Fund B", seat_count: 5)
    funder_a.portfolios.create!(name: "Climate")

    other = funder_b.portfolios.new(name: "Climate")
    assert other.valid?
  end

  test "active_memberships excludes suspended funder licenses" do
    funder_org = build_org("Funder Org 2")
    funder = funder_org.funders.create!(name: "Fund 2", seat_count: 5)
    portfolio = funder.portfolios.create!(name: "Climate")

    org_a = build_org("Org A")
    org_b = build_org("Org B")
    fm_a = FunderMembership.assign!(funder: funder, organisation: org_a)
    fm_b = FunderMembership.assign!(funder: funder, organisation: org_b)
    portfolio.portfolio_memberships.create!(funder_membership: fm_a)
    portfolio.portfolio_memberships.create!(funder_membership: fm_b)

    fm_b.suspend!

    assert_equal [ org_a.id ],
      portfolio.active_memberships.map { |pm| pm.funder_membership.organisation_id }
  end

  test "archive! marks deleted_at and excludes the portfolio from the kept scope" do
    funder_org = build_org("Funder Org 3")
    funder = funder_org.funders.create!(name: "Fund 3", seat_count: 5)
    portfolio = funder.portfolios.create!(name: "Education")

    portfolio.archive!

    assert portfolio.deleted_at.present?
    refute_includes Portfolio.kept, portfolio
    assert_includes Portfolio.archived, portfolio
  end
end
