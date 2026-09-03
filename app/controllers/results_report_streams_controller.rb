# Streams the AI report markdown to the modal as it's generated, so it types out
# live (like the Ask-Verto insights summary) instead of waiting on a spinner.
# The full text is cached on completion (shared with the PDF + Drive exports).
class ResultsReportStreamsController < ApplicationController
  include ActionController::Live
  include GeneratesResultsReport
  include LimitsConcurrentStreams
  include ThrottlesAiSpend

  limit_concurrent_streams only: :show

  # Same reasoning as the summaries: a plain open replays the cached markdown
  # and costs nothing, so this isn't counted against the daily cap. The limit
  # is lower than the chat's because ?regenerate=1 forces a full report — the
  # single most expensive Claude call in the app (P0-4).
  throttle_ai to: 30, within: 1.hour, name: "ai-report", respond: :plain, only: %i[ show ]

  def show
    survey = Current.organisation.surveys.find(params[:survey_id])

    # A viewer sees results, and a report that doesn't exist yet is a result
    # nobody has seen — so their first Generate goes through. The explicit
    # Regenerate on one that already exists is a different act: a deliberate
    # rewrite under a brief of their own, discarding the stored text (a
    # colleague's hand edits included), which is editing. Only that click is
    # refused: the cache's own refresh when responses change is the same for
    # every role and stays as it is. Answered in the plain-text language this
    # endpoint speaks, before the stream opens.
    if params[:regenerate].present? && !can_edit_vertos? && survey.results_report.present?
      return render plain: t("flash.organisation_scope.viewer_read_only"), status: :forbidden
    end

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    # The modal's explicit Generate click regenerates (never replays the
    # cache) and carries the creator's report brief; a plain open replays.
    force = params[:regenerate].present?
    brief = force ? params.permit(:goal, :audience, :length, sections: []).to_h.compact_blank : nil

    stream_results_report(survey, brief: brief, force: force) { |chunk| response.stream.write(chunk) }
  rescue ActiveRecord::RecordNotFound
    raise # clean 404 before the stream is opened
  rescue => e
    ErrorReporting.report("ResultsReportStreamsController", e)
    response.stream.write("\n\nReport unavailable right now.") rescue nil
  ensure
    response.stream.close if response.committed?
  end
end
