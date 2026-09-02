# The materialised leaderboard: one row per ranked identity per Verto, so the
# thank-you screen's auto-fetched board is an indexed read instead of a scan
# of every completed response per finisher.
#
# Refreshes are INCREMENTAL. The first design recomputed and rewrote the whole
# board per debounce window; the load test measured that at 50,000
# identities — 50k rows materialised in Ruby and delete+inserted every 3 s,
# which OOM-killed a 512 MB instance and would have been ~30k row writes/s on
# Postgres for a whole event. Now a refresh upserts only the identities whose
# responses changed since the snapshot's own high-water mark, and rank is
# derived at read time from the indexed (survey_id, total) column, so nothing
# is ever renumbered.
#
# Staleness contract: a snapshot may trail reality by the debounce window.
# The player endpoint splices a fresh finisher's own entry in from their own
# rows (see PlayerController#leaderboard), so nobody ever loads a thank-you
# screen that pretends they don't exist.
class LeaderboardStanding < ApplicationRecord
  belongs_to :survey

  validates :key_digest, presence: true

  # Identities per upsert batch during a full rebuild — bounds the Ruby
  # working set to a few hundred identities' rows whatever the board size.
  BATCH = 500
  # How far behind the snapshot's high-water mark an incremental refresh looks.
  # Upserts are idempotent, so over-selecting only costs a few extra rows;
  # under-selecting would lose a finisher until their next completion.
  WATERMARK_SLACK = 10.seconds

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

  # Bring this Verto's board up to date. With an existing snapshot only the
  # identities whose completed responses changed since the high-water mark
  # are recomputed; with none, the whole board is built in bounded batches.
  # Either way stale rows (identities whose completed responses vanished —
  # the consent-decline purge) are removed by one SQL anti-join, and the
  # whole refresh is one transaction so a failure leaves the previous
  # snapshot — and its watermark — intact.
  def self.refresh!(survey)
    since = where(survey_id: survey.id).maximum(:updated_at)
    scope = survey.responses.where(status: "completed").where.not(player_key_digest: nil)
    scope = scope.where("updated_at >= ?", since - WATERMARK_SLACK) if since
    digests = scope.distinct.pluck(:player_key_digest)

    transaction do
      digests.each_slice(BATCH) { |slice| upsert_entries!(survey, slice) }
      purge_stale!(survey)
    end
    digests.length
  end

  # First-read bootstrap: a board that has never been built (feature just
  # enabled, fresh environment) computes once inline so the first viewer sees
  # standings rather than an empty board. The cache claim stops a burst of
  # simultaneous first readers from all rebuilding at once — the losers serve
  # whatever exists (possibly empty) for a few seconds. No-op under the null
  # store in test, where every read rebuilds, which is what the tests want.
  def self.bootstrap!(survey)
    return if exists?(survey_id: survey.id)
    return unless Rails.cache.write("leaderboard-bootstrap:#{survey.id}", 1,
                                    unless_exist: true, expires_in: 1.minute)

    refresh!(survey)
  end

  # Recompute the board entries for these identities from their own completed
  # rows (one indexed query) and upsert them. Identities in `digests` that
  # turn out to have no completed rows are left to purge_stale!.
  def self.upsert_entries!(survey, digests)
    runs = Hash.new { |h, k| h[k] = [] }
    survey.responses.where(status: "completed", player_key_digest: digests)
          .select(:id, :player_key_digest, :token_totals, :completed_at, :created_at)
          .each do |resp|
      totals = resp.token_totals.is_a?(Hash) ? resp.token_totals : {}
      runs[resp.player_key_digest] << { total: totals.values.sum(&:to_i),
                                        at: resp.completed_at || resp.created_at,
                                        id: resp.id }
    end
    return 0 if runs.empty?

    now    = Time.current
    policy = survey.leaderboard_retake_policy
    rows = runs.map do |digest, list|
      list.sort_by! { |r| [ r[:at] || Time.at(0), r[:id] ] }
      e = TokenLeaderboard.entry_for(policy, digest, list)
      { survey_id: survey.id, key_digest: digest, total: e[:total],
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
