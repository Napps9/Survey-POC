# Streams the AI report markdown to the modal as it's generated, so it types out
# live (like the Ask-Verto insights summary) instead of waiting on a spinner.
# The full text is cached on completion (shared with the PDF + Drive exports).
class ResultsReportStreamsController < ApplicationController
  include ActionController::Live
  include GeneratesResultsReport

  def show
    survey = Current.organisation.surveys.find(params[:survey_id])

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    # The modal's explicit Generate click regenerates (never replays the
    # cache) and carries the creator's report brief; a plain open replays.
    force = params[:regenerate].present?
    brief = force ? params.permit(:goal, :audience, :length).to_h.compact_blank : nil

    stream_results_report(survey, brief: brief, force: force) { |chunk| response.stream.write(chunk) }
  rescue ActiveRecord::RecordNotFound
    raise # clean 404 before the stream is opened
  rescue => e
    Rails.logger.error("[ResultsReportStreamsController] #{e.class}: #{e.message}")
    response.stream.write("\n\nReport unavailable right now.") rescue nil
  ensure
    response.stream.close if response.committed?
  end
end
