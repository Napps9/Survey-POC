require "test_helper"

# The precomputed leaderboard snapshot: refresh! must reproduce
# TokenLeaderboard.standings exactly (same entries, same order, rank = index+1)
# and replace the previous snapshot atomically. Completions enqueue a debounced
# refresh; the snapshot is derived data and safe to rebuild at any time.
class LeaderboardStandingTest < ActiveSupport::TestCase
  TOKEN_TYPES = [ { "id" => "pts", "name" => "Points", "icon" => "⭐" } ].freeze
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B],
      "tokens" => { "A" => { "pts" => 5 }, "B" => { "pts" => 2 } } }
  ].freeze

  def setup
    org = Organisation.create!(name: "O", slug: "ls-#{SecureRandom.hex(3)}")
    @survey = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      tokenisation_enabled: true, token_types: TOKEN_TYPES, leaderboard_enabled: true,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def complete!(digest, choice, at: Time.current)
    @survey.responses.create!(
      session_token: "s-#{SecureRandom.hex(4)}", status: "completed",
      answers: { "1" => { "type" => "multiple_choice", "value" => choice } },
      token_totals: TokenGrading.totals(@survey.cards, { "1" => { "type" => "multiple_choice", "value" => choice } }, @survey.token_type_ids),
      player_key_digest: digest, completed_at: at
    )
  end

  test "refresh! materialises TokenLeaderboard.standings with dense ranks" do
    complete!("d-low", "B")
    complete!("d-high", "A")

    LeaderboardStanding.refresh!(@survey)
    rows = @survey.leaderboard_standings.order(:rank)

    expected = TokenLeaderboard.standings(@survey)
    assert_equal expected.map { |e| e[:key_digest] }, rows.map(&:key_digest)
    assert_equal expected.map { |e| e[:total] },      rows.map(&:total)
    assert_equal (1..expected.size).to_a,             rows.map(&:rank)
    assert_equal "d-high", rows.first.key_digest
  end

  test "refresh! materialises each type's total beside the ranked one" do
    complete!("d-high", "A")
    LeaderboardStanding.refresh!(@survey)

    row = @survey.leaderboard_standings.find_by!(key_digest: "d-high")
    assert_equal 5, row.total
    assert_equal({ "pts" => 5 }, row.totals)
  end

  test "refresh! replaces the previous snapshot rather than accumulating" do
    complete!("d1", "A")
    LeaderboardStanding.refresh!(@survey)
    complete!("d2", "B")
    LeaderboardStanding.refresh!(@survey)

    assert_equal 2, @survey.leaderboard_standings.count
    assert_equal 1, @survey.leaderboard_standings.where(key_digest: "d1").count
  end

  test "bootstrap! computes only when the snapshot has never been built" do
    complete!("d1", "A")
    assert_equal 0, @survey.leaderboard_standings.count

    LeaderboardStanding.bootstrap!(@survey)
    assert_equal 1, @survey.leaderboard_standings.count

    complete!("d2", "B")
    LeaderboardStanding.bootstrap!(@survey)
    assert_equal 1, @survey.leaderboard_standings.count, "an existing snapshot must not recompute on read"
  end

  test "a completion enqueues the debounced refresh job" do
    assert_enqueued_with(job: RefreshLeaderboardStandingsJob, args: [ @survey.id ]) do
      complete!("d1", "A")
    end
  end

  test "the consent-decline purge (digest nilled on a completed row) re-enqueues a refresh" do
    resp = complete!("d1", "A")
    LeaderboardStanding.refresh!(@survey)

    assert_enqueued_with(job: RefreshLeaderboardStandingsJob, args: [ @survey.id ]) do
      resp.update!(player_key_digest: nil)
    end
    RefreshLeaderboardStandingsJob.perform_now(@survey.id)
    assert_equal 0, @survey.leaderboard_standings.count, "a purged identity must leave the board"
  end

  test "the job is a no-op for a survey without an active leaderboard" do
    complete!("d1", "A")
    @survey.update!(leaderboard_enabled: false)

    RefreshLeaderboardStandingsJob.perform_now(@survey.id)
    assert_equal 0, @survey.leaderboard_standings.count
  end
end
