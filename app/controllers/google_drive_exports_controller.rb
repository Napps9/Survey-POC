# POST /surveys/:survey_id/results/google_drive
# Saves the AI results report as a Google Doc in the current user's Drive and
# returns its URL as JSON (the front-end opens it in a new tab). Reuses the same
# per-user OAuth connection as the Sheets export — its drive.file scope already
# covers files the app creates, so no extra consent is needed. Returns
# reconnect:true with the connect URL when the user isn't connected.
class GoogleDriveExportsController < ApplicationController
  include GeneratesResultsReport

  def create
    survey = Current.organisation.surveys.find(params[:survey_id])

    unless GoogleOauthService.configured?
      return render json: { ok: false, error: "Google isn't configured." }, status: :service_unavailable
    end
    return render_reconnect(survey) unless Current.user.google_connected?

    markdown = results_report_markdown(survey)
    result   = GoogleDriveWriter.call(
      user:  Current.user,
      title: doc_title(survey),
      # Tables rather than bar charts: Drive's HTML-to-Doc conversion
      # doesn't carry div-width bars, so the Doc gets the same numbers
      # in a form it can actually render.
      html:  results_report_document(survey, markdown, charts: false)
    )

    render json: { ok: true, url: result.url }
  rescue GoogleOauthService::NotConnected
    Current.user.disconnect_google!
    render_reconnect(survey)
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Verto not found." }, status: :not_found
  rescue => e
    ErrorReporting.report("GoogleDriveExportsController", e)
    render json: { ok: false, error: "Couldn't save to Google Drive — please try again." }, status: :unprocessable_entity
  end

  private

  def render_reconnect(survey)
    render json: {
      ok: false, reconnect: true,
      connect_url: google_connect_path(survey_id: survey&.id || params[:survey_id])
    }, status: :unprocessable_entity
  end

  def doc_title(survey)
    base = survey.theme.presence || survey.title.presence || "Verto"
    "#{base} — Verto results report"
  end
end
