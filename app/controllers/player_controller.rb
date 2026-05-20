class PlayerController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"
  skip_before_action :require_authentication
  skip_before_action :set_current_organisation
  protect_from_forgery with: :null_session, only: [:submit, :progress]

  before_action :load_survey_and_share

  def show
    return render plain: "Survey not found", status: :not_found unless @survey
    return render plain: "This Verto is no longer available.", status: :gone if @survey.deleted?
  end

  # Partial save while the player is mid-survey, so we can count people who
  # answered at least one question even if they never reach Submit. Idempotent
  # per session_token (a refresh reuses the token) and never downgrades a
  # response that has already been completed.
  def progress
    return render json: { ok: false }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = Response.find_or_initialize_by(session_token: token)
    resp.survey       ||= @survey
    resp.survey_share ||= @survey_share
    resp.answers = data["answers"] || {}
    # NB: the status column defaults to "completed", so a freshly initialized
    # record already reads "completed" — only preserve it for rows already saved
    # as completed (a late progress ping after submit), otherwise mark "started".
    resp.status  = "started" unless resp.persisted? && resp.status == "completed"
    resp.save!
    render json: { ok: true, session_token: token }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  def submit
    return render json: { ok: false, error: "Survey not found" }, status: :not_found unless @survey
    return render json: { ok: false, error: "This Verto is no longer available." }, status: :gone if @survey.deleted?
    data  = JSON.parse(request.body.read)
    token = data["session_token"].presence || SecureRandom.uuid
    resp  = Response.find_or_initialize_by(session_token: token)
    resp.survey       ||= @survey
    resp.survey_share ||= @survey_share
    resp.update!(answers: data["answers"] || {}, status: "completed")
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
