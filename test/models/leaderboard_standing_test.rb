require "test_helper"

# The precomputed leaderboard snapshot. refresh! must agree with
# TokenLeaderboard.standings (same entries, same order) while only ever
# touching the identities that changed: rank is derived at read time, the
# snapshot's own updated_at is the incremental high-water mark, and vanished
# identities are purged set-wise. Completions enqueue a debounced refresh; the
# snapshot is derived data and safe to rebuild at any time.
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

  def board
    @survey.leaderboard_standings.ranked.to_a
  end

  test "refresh! materialises TokenLeaderboard.standings in the same order" do
    complete!("d-low", "B")
    complete!("d-high", "A")

    LeaderboardStanding.refresh!(@survey)

    expected = TokenLeaderboard.standings(@survey)
    assert_equal expected.map { |e| e[:key_digest] }, board.map(&:key_digest)
    assert_equal expected.map { |e| e[:total] },      board.map(&:total)
    assert_equal "d-high", board.first.key_digest
  end

  test "rank_of is the 1-based position in ranked order, ties to the earlier achiever" do
    t = Time.current
    complete!("d-first",  "A", at: t - 60)
    complete!("d-second", "A", at: t - 30)
    complete!("d-low",    "B", at: t - 90)
    LeaderboardStanding.refresh!(@survey)

    ranks = board.map { |s| LeaderboardStanding.rank_of(@survey, total: s.total, achieved_at: s.achieved_at, key_digest: s.key_digest) }
    assert_equal [ 1, 2, 3 ], ranks
    assert_equal %w[d-first d-second d-low], board.map(&:key_digest)
  end

  test "rank_of never counts the identity's own stale row" do
    complete!("d1", "A")
    complete!("d2", "B")
    LeaderboardStanding.refresh!(@survey)

    # d1 is on the snapshot with 5; a live estimate for d1 at a LOWER total
    # (a restart-policy retake) must not see its own old row ahead of it.
    assert_equal 2, LeaderboardStanding.rank_of(@survey, total: 1, achieved_at: Time.current, key_digest: "d1")
  end

  test "refresh! replaces an identity's row rather than accumulating" do
    complete!("d1", "A")
    LeaderboardStanding.refresh!(@survey)
    complete!("d2", "B")
    LeaderboardStanding.refresh!(@survey)

    assert_equal 2, @survey.leaderboard_standings.count
    assert_equal 1, @survey.leaderboard_standings.where(key_digest: "d1").count
  end

  test "an incremental refresh touches only identities that changed since the watermark" do
    complete!("d-old", "A")
    LeaderboardStanding.refresh!(@survey)
    old_row = @survey.leaderboard_standings.find_by!(key_digest: "d-old")
    # Age both past the slack window, responses older than the snapshot as
    # they always are in reality (the watermark is stamped AFTER the rows it
    # covers were written).
    watermark = 1.hour.ago.change(usec: 0)
    @survey.leaderboard_standings.update_all(updated_at: watermark)
    @survey.responses.update_all(updated_at: watermark - 2.hours)

    complete!("d-new", "B")
    refreshed = LeaderboardStanding.refresh!(@survey)

    assert_equal 1, refreshed, "only the new finisher should be recomputed"
    assert_equal 2, @survey.leaderboard_standings.count
    untouched = @survey.leaderboard_standings.find_by!(key_digest: "d-old")
    assert_equal watermark.to_i, untouched.updated_at.to_i, "untouched rows keep their timestamp"
    assert_equal old_row.total, untouched.total
  end

  test "a full rebuild streams in batches and matches the one-shot answer" do
    stub_const_batch(2) do
      complete!("d1", "A"); complete!("d2", "B"); complete!("d3", "A"); complete!("d4", "B"); complete!("d5", "A")
      LeaderboardStanding.refresh!(@survey)
    end
    expected = TokenLeaderboard.standings(@survey)
    assert_equal expected.map { |e| e[:key_digest] }, board.map(&:key_digest)
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

  test "the consent-decline purge (digest nilled on a completed row) re-enqueues a refresh and leaves the board" do
    resp = complete!("d1", "A")
    complete!("d2", "B")
    LeaderboardStanding.refresh!(@survey)

    assert_enqueued_with(job: RefreshLeaderboardStandingsJob, args: [ @survey.id ]) do
      resp.update!(player_key_digest: nil)
    end
    RefreshLeaderboardStandingsJob.perform_now(@survey.id)
    assert_equal %w[d2], board.map(&:key_digest), "a purged identity must leave the board; the rest stay"
  end

  test "the job is a no-op for a survey without an active leaderboard" do
    complete!("d1", "A")
    @survey.update!(leaderboard_enabled: false)

    RefreshLeaderboardStandingsJob.perform_now(@survey.id)
    assert_equal 0, @survey.leaderboard_standings.count
  end

  private

  def stub_const_batch(n)
    old = LeaderboardStanding::BATCH
    LeaderboardStanding.send(:remove_const, :BATCH)
    LeaderboardStanding.const_set(:BATCH, n)
    yield
  ensure
    LeaderboardStanding.send(:remove_const, :BATCH)
    LeaderboardStanding.const_set(:BATCH, old)
  end
end
