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
  rescue ReportBusy
    render json: { ok: false, error: LimitsConcurrentStreams::BUSY_MESSAGE }, status: :service_unavailable
  rescue Google::Apis::AuthorizationError
    # The refresh worked but Drive rejected the access token: revoked since,
    # or granted without this scope. Either way the fix is a reconnect.
    Current.user.disconnect_google!
    render_reconnect(survey)
  rescue Google::Apis::ClientError => e
    # Already reported by GoogleDriveWriter. A 4xx from Drive is something a
    # person has to act on (an API left disabled in the Cloud project, a
    # consent missing this scope), so say which rather than "try again" —
    # retrying a 403 just produces another 403.
    if scope_insufficient?(e)
      Current.user.disconnect_google!
      render_reconnect(survey)
    else
      render json: { ok: false, error: drive_error_message(e) }, status: :unprocessable_entity
    end
  rescue => e
    ErrorReporting.report("GoogleDriveExportsController", e)
    render json: { ok: false, error: "Couldn't save to Google Drive — please try again." }, status: :unprocessable_entity
  end

  private

  # Google's 403 for a token whose consent didn't include drive.file (a
  # connection made before the scope existed, or trimmed on the consent
  # screen). The reconnect prompt re-asks for the current scope set.
  def scope_insufficient?(error)
    error.status_code == 403 && error.message.to_s.match?(/insufficient|SCOPE_INSUFFICIENT/i)
  end

  # google-apis-core formats a 4xx as "reason: message", both from the
  # error body, so the reason is what to key on.
  def drive_error_message(error)
    if error.message.to_s.match?(/accessNotConfigured|has not been used in project|is disabled/i)
      "Google Drive isn't enabled for this app: the Google Drive API must be turned on in the " \
      "Google Cloud project that owns its OAuth client (APIs & Services → Library → Google Drive API)."
    else
      detail = error.message.to_s.sub(/\A\w+:\s*/, "").strip
      "Google Drive declined the request#{detail.present? ? ": #{detail}" : ""}"
    end
  end

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
