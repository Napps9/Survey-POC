# Google sign-in. Mounted only when credentials are configured — the
# sign-in/up pages show exactly the buttons this initializer enables (both
# read SocialAuth). The request phase is POST-only with a CSRF token
# (omniauth-rails_csrf_protection), per OmniAuth 2.x guidance.
Rails.application.config.middleware.use OmniAuth::Builder do
  if SocialAuth.enabled?(:google_oauth2)
    provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"],
             scope: "email,profile"
  end
end

OmniAuth.config.allowed_request_methods = [ :post ]
OmniAuth.config.silence_get_warning = true

# Pin the callback host so the redirect_uri Google receives is always the
# canonical https URL, independent of the scheme Render's proxy forwards —
# the usual cause of redirect_uri_mismatch in production. Mirrors the host
# resolution in mailer.rb. Left unset in dev/test, where OmniAuth derives
# http://localhost from the request.
if (host = ENV["APP_HOST"].presence || ENV["RENDER_EXTERNAL_HOSTNAME"].presence)
  OmniAuth.config.full_host = "#{ENV.fetch('APP_PROTOCOL', 'https')}://#{host}"
end
