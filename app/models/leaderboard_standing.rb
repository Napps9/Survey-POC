# The materialised leaderboard: TokenLeaderboard.standings, written to a
# table so reads are indexed lookups instead of a scan of every completed
# response. The scan still happens — once per refresh, in
# RefreshLeaderboardStandingsJob, debounced to a few seconds — rather than
# once per finisher, which is the difference between ~200 scans across a
# 50,000-respondent burst and 50,000 of them.
#
# Staleness contract: a snapshot may trail reality by the debounce window.
# The player endpoint splices a fresh finisher's own entry in from their own
# rows (see PlayerController#leaderboard), so nobody ever loads a thank-you
# screen that pretends they don't exist.
class LeaderboardStanding < ApplicationRecord
  belongs_to :survey

  validates :key_digest, :rank, presence: true

  # Recompute and atomically replace this Verto's standings. The delete +
  # insert runs in one transaction so readers never see a half-written board,
  # and insert_all skips callbacks/validations the same way the importer does
  # — these rows are derived data, fully re-derivable at any time.
  def self.refresh!(survey)
    entries = TokenLeaderboard.standings(survey)
    now = Time.current
    rows = entries.each_with_index.map do |e, i|
      { survey_id: survey.id, key_digest: e[:key_digest], total: e[:total],
        achieved_at: e[:achieved_at], rank: i + 1, created_at: now, updated_at: now }
    end

    transaction do
      where(survey_id: survey.id).delete_all
      insert_all!(rows) if rows.any?
    end
    rows.length
  end

  # First-read bootstrap: a board that has never been refreshed (feature just
  # enabled, fresh environment) computes once inline so the first viewer sees
  # standings rather than an empty board. An genuinely empty board (no
  # completed identities yet) recomputes trivially — the scan finds nothing.
  def self.bootstrap!(survey)
    refresh!(survey) unless exists?(survey_id: survey.id)
  end
end
