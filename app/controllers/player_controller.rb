class PlayerController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  protect_from_forgery with: :null_session, only: :submit

  before_action :load_survey_and_share

  def show
    return render plain: "Survey not found", status: :not_found unless @survey
    return render plain: "This Verto is no longer available.", status: :gone if @survey.deleted?
  end

  def submit
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    data = JSON.parse(request.body.read)
    Response.create!(
      survey:        @survey,
      survey_share:  @survey_share,
      session_token: data["session_token"] || SecureRandom.uuid,
      answers:       data["answers"] || {},
      status:        "completed"
    )
    render json: { ok: true }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  def results
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    unless @survey.show_results_comparison?
      return render json: { ok: false, error: "Comparison not enabled" }, status: :forbidden
    end

    responses  = @survey.responses.where(status: "completed")
    aggregated = aggregate_results(Array(@survey.cards), responses).map.with_index do |row, idx|
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
  end

  private

  def load_survey_and_share
    token = params[:token]
    if (share = SurveyShare.find_by(share_token: token))
      @survey_share = share
      @survey = share.survey
    else
      @survey = Survey.find_by(publish_token: token)
    end
  end
end
