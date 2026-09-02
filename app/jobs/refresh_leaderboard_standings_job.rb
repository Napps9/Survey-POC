# Brings one Verto's precomputed leaderboard (LeaderboardStanding) up to date
# after completions. Enqueued from Response's after_commit with a short cache
# debounce, so a burst of finishers coalesces into one refresh every few
# seconds instead of one scan per finisher.
class RefreshLeaderboardStandingsJob < ApplicationJob
  queue_as :default

  # Standings are derived data and the next completion re-enqueues, so a
  # failed refresh self-heals; retrying would only double the work.
  discard_on StandardError do |job, error|
    ErrorReporting.report("RefreshLeaderboardStandingsJob", error, survey_id: job.arguments.first)
  end

  def perform(survey_id)
    survey = Survey.find_by(id: survey_id)
    return unless survey&.leaderboard_active?

    return unless LeaderboardStanding.refresh!(survey) == :busy

    # Another refresh is mid-flight (a big first build, or the previous
    # window's pass overrunning). The finishers this window carried are still
    # in the responses table, so try again after one debounce — bounded by
    # the running refresh's own lifetime.
    self.class.set(wait: Response::REFRESH_STANDINGS_DEBOUNCE).perform_later(survey_id)
  end
end
