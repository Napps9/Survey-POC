require "test_helper"

# The standings math behind the leaderboard: how runs group into identities,
# what each retake policy counts, and how ties order. Pure policy logic —
# the endpoint's guards and shapes are covered by leaderboard_player_test.
class TokenLeaderboardTest < ActiveSupport::TestCase
  def setup
    org = Organisation.create!(name: "O", slug: "tl-#{SecureRandom.hex(3)}")
    @survey = org.surveys.create!(title: "T", theme: "T", audience_age: "all",
                                  key_insight: "x", default_locale: "en", locales: [ "en" ],
                                  tokenisation_enabled: true,
                                  token_types: [ { "id" => "gold", "name" => "Gold", "icon" => "🪙" } ],
                                  leaderboard_enabled: true)
  end

  def run!(digest, totals, at:, status: "completed")
    @survey.responses.create!(session_token: SecureRandom.uuid,
                              status: status,
                              player_key_digest: digest,
                              token_totals: totals,
                              completed_at: (status == "completed" ? at : nil))
  end

  test "accumulate sums an identity's runs; totals span every token type" do
    run! "a", { "gold" => 2, "coal" => 3 }, at: 3.hours.ago
    run! "a", { "gold" => 7 },             at: 1.hour.ago
    run! "b", { "gold" => 10 },            at: 2.hours.ago

    rows = TokenLeaderboard.standings(@survey)

    assert_equal [ [ "a", 12 ], [ "b", 10 ] ], rows.map { |r| [ r[:key_digest], r[:total] ] }
  end

  test "restart counts only the latest run" do
    run! "a", { "gold" => 9 }, at: 3.hours.ago
    run! "a", { "gold" => 4 }, at: 1.hour.ago
    @survey.update_column(:leaderboard_retake_policy, "restart")

    rows = TokenLeaderboard.standings(@survey)

    assert_equal 4, rows.first[:total], "a retake wipes the old score even when it was higher"
  end

  test "no_redo counts only the first run — stray retakes are stored but ignored" do
    run! "a", { "gold" => 4 }, at: 3.hours.ago
    run! "a", { "gold" => 9 }, at: 1.hour.ago
    @survey.update_column(:leaderboard_retake_policy, "no_redo")

    rows = TokenLeaderboard.standings(@survey)

    assert_equal 1, rows.size
    assert_equal 4, rows.first[:total],
      "the policy is scoring only: whether a retake may happen at all is the survey's " \
      "no_retests rule, so a stray extra row must simply not count"
  end

  test "ties order by who reached the total first" do
    run! "late",  { "gold" => 5 }, at: 1.hour.ago
    run! "early", { "gold" => 5 }, at: 3.hours.ago

    rows = TokenLeaderboard.standings(@survey)

    assert_equal %w[early late], rows.map { |r| r[:key_digest] },
      "a late equal score must never jump an earlier one"
  end

  test "identity-less and unfinished rows stay off the board; zero-token finishers stay on" do
    run! nil,  { "gold" => 99 }, at: 2.hours.ago
    run! "up", { "gold" => 3 },  at: 3.hours.ago, status: "started"
    run! "z",  {},               at: 1.hour.ago

    rows = TokenLeaderboard.standings(@survey)

    assert_equal [ [ "z", 0 ] ], rows.map { |r| [ r[:key_digest], r[:total] ] },
      "pre-feature rows can't be grouped (no identity) and started rows aren't results — " \
      "but a completed zero-token play still ranks, so 'you' always resolves"
  end
end
