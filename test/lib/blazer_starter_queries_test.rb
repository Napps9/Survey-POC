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

  test "resync! refreshes an out-of-date query back to the canonical SQL" do
    BlazerStarterQueries.create_missing!
    query = Blazer::Query.find_by!(name: BlazerStarterQueries::DEFINITIONS.first[:name])
    query.update!(statement: "SELECT 1")

    assert_equal 1, BlazerStarterQueries.resync!, "only the edited query should change"
    assert_not_equal "SELECT 1", query.reload.statement
  end
end
