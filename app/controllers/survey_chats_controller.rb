class SurveyChatsController < ApplicationController
  include ActionController::Live
  include AggregatesSurveyResults
  protect_from_forgery with: :null_session

  def create
    survey    = Survey.find(params[:survey_id])
    responses = survey.responses.where(status: "completed").order(created_at: :desc)
    total     = responses.count
    aggregated = aggregate_results(Array(survey.cards), responses)

    body     = JSON.parse(request.body.read)
    messages = Array(body["messages"]).last(20)

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    ResultsChat.new.call(
      survey:     survey,
      aggregated: aggregated,
      total:      total,
      messages:   messages
    ) do |chunk|
      response.stream.write(chunk)
    end
  rescue => e
    Rails.logger.error "[SurveyChatsController] #{e.class}: #{e.message}"
    response.stream.write("Sorry, I couldn't answer that right now.") rescue nil
  ensure
    response.stream.close
  end
end
