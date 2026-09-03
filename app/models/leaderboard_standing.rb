# The materialised leaderboard: one row per ranked identity per Verto, so the
# thank-you screen's auto-fetched board is an indexed read instead of a scan
# of every completed response per finisher.
#
# Refreshes are INCREMENTAL and SINGLE-FLIGHT. The first design recomputed and
# rewrote the whole board per debounce window; the load test measured that at
# 50,000 identities — 50k rows materialised in Ruby and delete+inserted every
# 3 s, which OOM-killed a 512 MB instance. The second design streamed the
# rebuild but wrapped it in one transaction, so until it committed every
# 3-second job saw "no snapshot" and started ANOTHER full rebuild — overlapping
# rebuilds in the web process queued every request behind them (~12 s medians
# at 2 arrivals/s). Now:
#
#   * the high-water mark is an explicit column (surveys.leaderboard_refreshed_at)
#     stamped only when a refresh completes, so a rebuild commits per batch
#     without a partial run ever masquerading as up to date;
#   * a cache claim makes refreshes single-flight — a concurrent caller gets
#     :busy and the job retries after the debounce;
#   * the first-read bootstrap builds inline only while the board is small;
#     a big one is handed to the job so no respondent request carries it.
#
# Rank is derived at read time from the indexed (survey_id, total) column, so
# nothing is ever renumbered. Staleness contract: a snapshot may trail reality
# by the debounce window; PlayerController#leaderboard splices a fresh
# finisher's own entry in from their own rows, so nobody ever loads a
# thank-you screen that pretends they don't exist.
class LeaderboardStanding < ApplicationRecord
  belongs_to :survey

  validates :key_digest, presence: true

  # Identities per upsert batch — bounds the Ruby working set to a few hundred
  # identities' rows whatever the board size.
  BATCH = 500
  # How far behind the watermark an incremental refresh looks. Upserts are
  # idempotent, so over-selecting only costs a few extra rows.
  WATERMARK_SLACK = 10.seconds
  # Longest a refresh may hold the single-flight claim before it is presumed
  # dead (the claim is released explicitly on every normal exit).
  LOCK_TTL = 10.minutes
  # Boards with more distinct identities than this are built by the job on
  # first read, not inline in the reader's request. Overridable for tests.
  class_attribute :inline_bootstrap_max, default: 2_000

  # Best first: highest total, earliest to reach it, digest as a stable tail.
  # achieved_at is always written non-null (completed_at || created_at), so
  # the ordering agrees on SQLite and Postgres, which sort NULLs differently.
  scope :ranked, -> { order(total: :desc, achieved_at: :asc, key_digest: :asc) }

  # 1-based position an entry with these values holds on this board: rows
  # strictly ahead of it in `ranked` order, plus one. Excludes the identity's
  # own (possibly stale) row so a live estimate never counts itself.
  def self.rank_of(survey, total:, achieved_at:, key_digest:)
    at = achieved_at || Time.at(0)
    board = where(survey_id: survey.id).where.not(key_digest: key_digest)
    board.where("total > ?", total)
         .or(board.where(total: total).where("achieved_at < ?", at))
         .or(board.where(total: total, achieved_at: at).where("key_digest < ?", key_digest))
         .count + 1
  end

  # Bring this Verto's board up to date and return how many identities were
  # recomputed — or :busy if another refresh holds the claim. With a
  # watermark only the identities whose completed responses changed since it
  # are recomputed; without one the whole board is built, batch by batch,
  # each batch its own transaction. Vanished identities (the consent-decline
  # purge) are removed by one SQL anti-join. The watermark is stamped with the
  # refresh's START time, and only on success, so a failed run is simply
  # redone by the next one.
  def self.refresh!(survey)
    claim = "leaderboard-refresh-lock:#{survey.id}"
    return :busy unless Rails.cache.write(claim, 1, unless_exist: true, expires_in: LOCK_TTL)

    begin
      started = Time.current
      since   = Survey.where(id: survey.id).pick(:leaderboard_refreshed_at)
      scope   = completed_identities(survey)
      scope   = scope.where("updated_at >= ?", since - WATERMARK_SLACK) if since
      digests = scope.distinct.pluck(:player_key_digest)

      digests.each_slice(BATCH) { |slice| transaction { upsert_entries!(survey, slice) } }
      purge_stale!(survey)
      Survey.where(id: survey.id).update_all(leaderboard_refreshed_at: started)
      digests.length
    ensure
      Rails.cache.delete(claim)
    end
  end

  # First-read bootstrap for a board that has never completed a refresh
  # (feature just enabled, fresh environment, seeded data). Small boards build
  # inline so the first viewer sees standings; big ones are handed to the job
  # and the viewer sees whatever exists so far. The cache claim keeps a burst
  # of first readers from enqueueing a job each (no-op under the null store).
  def self.bootstrap!(survey)
    return if Survey.where(id: survey.id).where.not(leaderboard_refreshed_at: nil).exists?

    sample = completed_identities(survey).select(:player_key_digest).distinct.limit(inline_bootstrap_max + 1)
    if Response.from(sample, :identities).count > inline_bootstrap_max
      return unless Rails.cache.write("leaderboard-bootstrap:#{survey.id}", 1,
                                      unless_exist: true, expires_in: 1.minute)

      RefreshLeaderboardStandingsJob.perform_later(survey.id)
    else
      refresh!(survey)
    end
  end

  def self.completed_identities(survey)
    survey.responses.where(status: "completed").where.not(player_key_digest: nil)
  end

  # Recompute the board entries for these identities from their own completed
  # rows (one indexed query) and upsert them. Identities in `digests` that
  # turn out to have no completed rows are left to purge_stale!.
  def self.upsert_entries!(survey, digests)
    runs     = Hash.new { |h, k| h[k] = [] }
    rank_by  = survey.leaderboard_rank_by
    type_ids = survey.token_type_ids
    survey.responses.where(status: "completed", player_key_digest: digests)
          .select(:id, :player_key_digest, :token_totals, :completed_at, :created_at)
          .each do |resp|
      runs[resp.player_key_digest] << TokenLeaderboard.run_for(resp, rank_by, type_ids)
    end
    return 0 if runs.empty?

    now    = Time.current
    policy = survey.leaderboard_retake_policy
    rows = runs.map do |digest, list|
      list.sort_by! { |r| [ r[:at] || Time.at(0), r[:id] ] }
      e = TokenLeaderboard.entry_for(policy, digest, list)
      # `total` is the basis the board ranks by (Survey#leaderboard_rank_by);
      # `totals` is every declared type's figure for the row's breakdown.
      { survey_id: survey.id, key_digest: digest, total: e[:total], totals: e[:totals],
        achieved_at: e[:achieved_at] || Time.at(0), created_at: now, updated_at: now }
    end
    upsert_all(rows, unique_by: [ :survey_id, :key_digest ], record_timestamps: false)
    rows.length
  end

  # Drop rows whose identity no longer has any completed response — set-based
  # and indexed (responses[survey_id, player_key_digest]) on both engines.
  def self.purge_stale!(survey)
    where(survey_id: survey.id)
      .where("NOT EXISTS (SELECT 1 FROM responses r WHERE r.survey_id = leaderboard_standings.survey_id " \
             "AND r.player_key_digest = leaderboard_standings.key_digest AND r.status = 'completed')")
      .delete_all
  end
end
