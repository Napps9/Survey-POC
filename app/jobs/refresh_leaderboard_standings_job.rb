# Rewrites one Verto's precomputed leaderboard (LeaderboardStanding) after
# completions. Enqueued from Response's after_commit with a short cache
# debounce, so a burst of finishers coalesces into one refresh every few
# seconds instead of one scan per finisher.
class RefreshLeaderboardStandingsJob < ApplicationJob
  queue_as :default

  # Standings are derived data and the next completion re-enqueues, so a
  # failed refresh self-heals; retrying would only double the scan.
  discard_on StandardError do |job, error|
    ErrorReporting.report("RefreshLeaderboardStandingsJob", error, survey_id: job.arguments.first)
  end

  def perform(survey_id)
    survey = Survey.find_by(id: survey_id)
    return unless survey&.leaderboard_active?

    LeaderboardStanding.refresh!(survey)
  end
end
