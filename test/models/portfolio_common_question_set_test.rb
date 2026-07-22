require "test_helper"

class PortfolioCommonQuestionSetTest < ActiveSupport::TestCase
  def build_org(name)
    Organisation.create!(name: name, slug: "#{name.parameterize}-#{SecureRandom.hex(3)}")
  end

  test "rejects a set owned by another organisation" do
    funder_org = build_org("Funder Org")
    funder = funder_org.funders.create!(name: "Fund", seat_count: 5)
    portfolio = funder.portfolios.create!(name: "Climate")

    other_org = build_org("Other Org")
    foreign_set = other_org.common_question_sets.create!(name: "Foreign")

    pcqs = PortfolioCommonQuestionSet.new(portfolio: portfolio, common_question_set: foreign_set)
    refute pcqs.valid?
    assert_includes pcqs.errors[:common_question_set], "must belong to the funder's own organisation"
  end

  test "accepts a set owned by the funder's own organisation" do
    funder_org = build_org("Funder Org 2")
    funder = funder_org.funders.create!(name: "Fund 2", seat_count: 5)
    portfolio = funder.portfolios.create!(name: "Education")
    own_set = funder_org.common_question_sets.create!(name: "Own")

    pcqs = PortfolioCommonQuestionSet.new(portfolio: portfolio, common_question_set: own_set)
    assert pcqs.valid?
  end

  test "uniqueness of common_question_set within a portfolio" do
    funder_org = build_org("Funder Org 3")
    funder = funder_org.funders.create!(name: "Fund 3", seat_count: 5)
    portfolio = funder.portfolios.create!(name: "Sport")
    set = funder_org.common_question_sets.create!(name: "Set")

    PortfolioCommonQuestionSet.create!(portfolio: portfolio, common_question_set: set)
    dup = PortfolioCommonQuestionSet.new(portfolio: portfolio, common_question_set: set)
    refute dup.valid?
  end
end
