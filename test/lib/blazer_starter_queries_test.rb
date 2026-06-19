require "test_helper"

class BlazerStarterQueriesTest < ActiveSupport::TestCase
  setup { Blazer::Query.delete_all }

  test "organisations are external (not internal) by default" do
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    assert_not org.internal
  end

  test "create_missing! creates every starter query and is idempotent" do
    assert_difference -> { Blazer::Query.count }, BlazerStarterQueries::DEFINITIONS.size do
      BlazerStarterQueries.create_missing!
    end
    assert_no_difference -> { Blazer::Query.count } do
      BlazerStarterQueries.create_missing!
    end
  end

  test "every starter query filters out internal organisations" do
    BlazerStarterQueries::DEFINITIONS.each do |definition|
      assert_includes definition[:statement], "internal",
                      "#{definition[:name]} must exclude internal organisations"
    end
  end

  test "create_missing! preserves edits the team made to an existing query" do
    BlazerStarterQueries.create_missing!
    query = Blazer::Query.find_by!(name: BlazerStarterQueries::DEFINITIONS.first[:name])
    query.update!(statement: "SELECT 42")

    BlazerStarterQueries.create_missing!
    assert_equal "SELECT 42", query.reload.statement
  end

  test "content queries expose per-Verto questions and answers via a {verto_id} picker" do
    names = BlazerStarterQueries::DEFINITIONS.map { |d| d[:name] }
    assert_includes names, "Content — Questions in a Verto"
    assert_includes names, "Content — Answers in a Verto"

    answers = BlazerStarterQueries::DEFINITIONS.find { |d| d[:name] == "Content — Answers in a Verto" }
    assert_includes answers[:statement], "{verto_id}"
    assert_includes answers[:statement], "json_array_elements", "must unpack the cards JSON array"
    assert_includes answers[:statement], "r.answers", "must read the players' answers"
  end

  test "creator-retention query builds weekly cohorts from first-Verto activity" do
    retention = BlazerStarterQueries::DEFINITIONS.find { |d| d[:name].include?("retention") }
    assert retention, "expected a creator-retention starter query"
    assert_includes retention[:statement], "cohort_week"
    assert_includes retention[:statement], "MIN(active_week)", "cohort = first active week"
    assert_includes retention[:statement], "weeks_since"
  end

  test "results query combines questions and answers in one view" do
    results = BlazerStarterQueries::DEFINITIONS.find { |d| d[:name] == "Content — Verto results (questions & answers)" }
    assert results, "expected a combined questions+answers results query"
    assert_includes results[:statement], "{verto_id}"
    assert_includes results[:statement], "json_array_elements", "must unpack the questions"
    assert_includes results[:statement], "r.answers", "must read the answers"
    assert_includes results[:statement], "internal", "must exclude internal orgs"
  end

  test "resync! refreshes an out-of-date query back to the canonical SQL" do
    BlazerStarterQueries.create_missing!
    query = Blazer::Query.find_by!(name: BlazerStarterQueries::DEFINITIONS.first[:name])
    query.update!(statement: "SELECT 1")

    assert_equal 1, BlazerStarterQueries.resync!, "only the edited query should change"
    assert_not_equal "SELECT 1", query.reload.statement
  end
end
