class SurveySummariesController < ApplicationController
  include ActionController::Live
  include AggregatesSurveyResults

  def show
    survey    = Current.organisation.surveys.find(params[:id])
    responses = survey.responses.where(status: "completed").order(created_at: :desc)
    total     = responses.count

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    if survey.results_summary.present? && survey.results_summary_response_count == total
      response.stream.write(survey.results_summary)
      return
    end

    aggregated = aggregate_results(Array(survey.cards), responses)
    full_text  = +""

    ResultsSummariser.new.call(survey: survey, aggregated: aggregated, total: total) do |chunk|
      response.stream.write(chunk)
      full_text << chunk
    end

    survey.update_columns(
      results_summary:                full_text,
      results_summary_response_count: total
    ) if full_text.present?
  rescue ActiveRecord::RecordNotFound
    raise # let Rails return a clean 404 before any stream is opened
  rescue => e
    Rails.logger.error "[SurveySummariesController] #{e.class}: #{e.message}"
    response.stream.write("Insights unavailable.") rescue nil
  ensure
    response.stream.close if response.committed?
  end
end
