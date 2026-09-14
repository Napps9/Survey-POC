# Google sign-in. Mounted only when credentials are configured — the
# sign-in/up pages show exactly the buttons this initializer enables (both
# read SocialAuth). The request phase is POST-only with a CSRF token
# (omniauth-rails_csrf_protection), per OmniAuth 2.x guidance.
Rails.application.config.middleware.use OmniAuth::Builder do
  if SocialAuth.enabled?(:google_oauth2)
    provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"],
             scope: "email,profile"
  end

  # The same Google client, mounted a second time under a name of its own, so
  # a RESPONDENT's sign-in comes back to /auth/google_player/callback and a
  # creator's to /auth/google_oauth2/callback. Two populations, two tables,
  # two cookies (see PlayerAuthentication) — and so two callback paths, rather
  # than one controller deciding which kind of account to mint from a flag
  # some earlier page left in the session. The URL Google was sent to is the
  # only thing that can say it, and the browser cannot forge it: it is fixed
  # at the redirect_uri Google itself validates.
  #
  # Needs its own authorized redirect URI on the client. See .env.example.
  if SocialAuth.player_enabled?(:google_player)
    provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"],
             name: "google_player", scope: "email,profile"
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
