class PlayerController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  protect_from_forgery with: :null_session, only: :submit

  def show
    @survey = Survey.find_by!(publish_token: params[:token])
  rescue ActiveRecord::RecordNotFound
    render plain: "Survey not found", status: :not_found
  end

  def submit
    survey = Survey.find_by!(publish_token: params[:token])
    data   = JSON.parse(request.body.read)
    Response.create!(
      survey:        survey,
      session_token: data["session_token"] || SecureRandom.uuid,
      answers:       data["answers"] || {},
      status:        "completed"
    )
    render json: { ok: true }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  def results
    survey = Survey.find_by!(publish_token: params[:token])
    unless survey.show_results_comparison?
      return render json: { ok: false, error: "Comparison not enabled" }, status: :forbidden
    end

    responses  = survey.responses.where(status: "completed")
    aggregated = aggregate_results(Array(survey.cards), responses).map.with_index do |row, idx|
      {
        index:  idx,
        type:   row[:type],
        prompt: row[:card]["text"] || row[:card]["prompt"] || row[:card]["title"],
        options: row[:card]["options"],
        total:  row[:total],
        counts: row[:counts],
        avg:    row[:avg]
      }
    end
    render json: { ok: true, total_responses: responses.count, results: aggregated }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Survey not found" }, status: :not_found
  end
end
