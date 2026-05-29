require "signet/oauth_2/client"

# Wraps the Google OAuth 2.0 authorization-code flow (Signet) for the per-user
# "Connect to Google Sheets" export. Stateless: tokens live on the User.
class GoogleOauthService
  AUTH_URI  = "https://accounts.google.com/o/oauth2/auth".freeze
  TOKEN_URI = "https://oauth2.googleapis.com/token".freeze
  # drive.file = per-file access to files the app creates — narrow scope, does
  # NOT expose the user's other Drive files. Enough to create + write a sheet.
  SCOPE     = "https://www.googleapis.com/auth/drive.file".freeze

  # Raised when the user has no usable refresh token (never connected, or revoked).
  class NotConnected < StandardError; end

  class << self
    def configured?
      ENV["GOOGLE_CLIENT_ID"].present? && ENV["GOOGLE_CLIENT_SECRET"].present?
    end

    # Consent-screen URL. access_type=offline + prompt=consent are required to
    # receive a refresh token (so later exports are one click).
    def authorization_url(redirect_uri:, state:)
      base_client(redirect_uri: redirect_uri,
                  additional_parameters: { "access_type" => "offline", "prompt" => "consent" })
        .authorization_uri(state: state).to_s
    end

    # Exchanges the callback code for tokens.
    def exchange_code!(code:, redirect_uri:)
      client = base_client(redirect_uri: redirect_uri)
      client.code = code
      client.fetch_access_token!
      { refresh_token: client.refresh_token, access_token: client.access_token, expires_at: client.expires_at }
    end

    # An authorized Signet client for the user, refreshed from their stored
    # refresh token. Raises NotConnected when missing or revoked.
    def client_for(user)
      raise NotConnected, "No Google refresh token" if user.google_refresh_token.blank?

      client = Signet::OAuth2::Client.new(
        token_credential_uri: TOKEN_URI,
        client_id:            ENV["GOOGLE_CLIENT_ID"],
        client_secret:        ENV["GOOGLE_CLIENT_SECRET"],
        refresh_token:        user.google_refresh_token,
        scope:                SCOPE
      )
      client.fetch_access_token!
      client
    rescue Signet::AuthorizationError => e
      raise NotConnected, e.message
    end

    private

    def base_client(redirect_uri:, **extra)
      Signet::OAuth2::Client.new(
        authorization_uri:    AUTH_URI,
        token_credential_uri: TOKEN_URI,
        client_id:            ENV["GOOGLE_CLIENT_ID"],
        client_secret:        ENV["GOOGLE_CLIENT_SECRET"],
        scope:                SCOPE,
        redirect_uri:         redirect_uri,
        **extra
      )
    end
  end
end
