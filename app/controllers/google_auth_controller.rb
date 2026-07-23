# The Google OAuth dance for the "Connect to Google Sheets" export.
#   GET /google/connect  → redirect to Google's consent screen
#   GET /google/callback → store tokens on the current user, return to results
# Feedback is passed back as query params (?google_connected / ?google_error)
# because the fullscreen results layout doesn't render flash.
class GoogleAuthController < ApplicationController
  def connect
    unless GoogleOauthService.configured?
      return redirect_to results_or_root(params[:survey_id], params[:segment], google_error: 1)
    end

    state = SecureRandom.urlsafe_base64(24)
    session[:google_oauth_state]  = state
    session[:google_oauth_return] = {
      "survey_id" => params[:survey_id], "segment" => params[:segment], "to" => params[:return_to]
    }

    redirect_to GoogleOauthService.authorization_url(redirect_uri: google_callback_url, state: state),
                allow_other_host: true
  end

  def callback
    ret      = session.delete(:google_oauth_return) || {}
    expected = session.delete(:google_oauth_state)

    if params[:error].present? || expected.blank? || params[:state] != expected
      return redirect_to return_target(ret, google_error: 1)
    end

    tokens = GoogleOauthService.exchange_code!(code: params[:code], redirect_uri: google_callback_url)

    attrs = {
      google_access_token:     tokens[:access_token],
      google_token_expires_at: tokens[:expires_at],
      google_connected_at:     Time.current
    }
    # Google only returns a refresh token on first consent — never clobber a
    # stored one with nil.
    attrs[:google_refresh_token] = tokens[:refresh_token] if tokens[:refresh_token].present?
    Current.user.update!(attrs)

    redirect_to return_target(ret, google_connected: 1)
  rescue => e
    ErrorReporting.report("GoogleAuthController", e)
    redirect_to return_target(ret, google_error: 1)
  end

  private

  # Where the connect flow drops back to: the Verto-import wizard or the
  # dashboard's own "Create a Form" modal when it was started from there,
  # otherwise the results page (Sheets export) or root.
  def return_target(ret, **flags)
    return new_survey_path(**flags) if ret["to"] == "import"
    return root_path(**flags, open_import: 1) if ret["to"] == "dashboard_import"
    results_or_root(ret["survey_id"], ret["segment"], **flags)
  end

  def results_or_root(survey_id, segment, **flags)
    return root_path if survey_id.blank?
    survey_results_path(survey_id, segment: segment, **flags)
  end
end
