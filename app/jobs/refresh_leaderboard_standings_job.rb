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
    # in the responses table, so try again after one debounce — through the
    # same claim Response uses to enqueue, so however many busy jobs stack up
    # behind a long build there is only ever ONE retry pending per window,
    # not a chain per job.
    claimed = Rails.cache.write("leaderboard-refresh:#{survey_id}", 1,
                                unless_exist: true, expires_in: Response::REFRESH_STANDINGS_DEBOUNCE)
    return unless claimed

    self.class.set(wait: Response::REFRESH_STANDINGS_DEBOUNCE).perform_later(survey_id)
  end
end
