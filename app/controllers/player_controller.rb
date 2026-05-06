class PlayerController < ApplicationController
  layout "fullscreen"
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
end
