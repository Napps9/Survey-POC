# Pushes the live results tally (ResultsActivity) from a background job.
# Response's after_commit used to broadcast inline — two COUNT queries, a
# partial render and a Solid Cable INSERT on the respondent's own request
# thread, up to twice per respondent, whether or not anyone was watching. The
# callback now claims a short cache window and schedules ONE of these per
# Verto per window, so a burst of finishers costs one tally push every few
# seconds instead of one per finisher.
class BroadcastResultsActivityJob < ApplicationJob
  queue_as :default

  # The tally is a nicety over derived data; the next transition re-enqueues.
  discard_on StandardError do |job, error|
    ErrorReporting.report("BroadcastResultsActivityJob", error, survey_id: job.arguments.first)
  end

  def perform(survey_id)
    survey = Survey.find_by(id: survey_id)
    return unless survey

    ResultsActivity.broadcast(survey)
  end
end
