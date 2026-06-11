# Social sign-in strategies. Only configured providers are mounted — the
# sign-in/up pages show exactly the buttons this initializer enables (both
# read SocialAuth). The request phase is POST-only with a CSRF token
# (omniauth-rails_csrf_protection), per OmniAuth 2.x guidance.
Rails.application.config.middleware.use OmniAuth::Builder do
  if SocialAuth.enabled?(:google_oauth2)
    provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"],
             scope: "email,profile"
  end

  if SocialAuth.enabled?(:entra_id)
    # tenant "common" accepts both work/school (Entra ID — what Teams users
    # have) and personal Microsoft accounts.
    provider :entra_id, {
      client_id:     ENV["MICROSOFT_CLIENT_ID"],
      client_secret: ENV["MICROSOFT_CLIENT_SECRET"],
      tenant_id:     ENV.fetch("MICROSOFT_TENANT_ID", "common")
    }
  end

  if SocialAuth.enabled?(:apple)
    # Apple posts the callback cross-site (response_mode=form_post is
    # mandatory when requesting name/email), so the Lax session cookie — and
    # with it OmniAuth's state — isn't sent. The gem's id_token nonce check
    # covers replay/CSRF instead, hence provider_ignores_state.
    provider :apple, ENV["APPLE_CLIENT_ID"], "", {
      scope:   "email name",
      team_id: ENV["APPLE_TEAM_ID"],
      key_id:  ENV["APPLE_KEY_ID"],
      pem:     ENV["APPLE_PRIVATE_KEY"].to_s.gsub('\n', "\n"),
      provider_ignores_state: true
    }
  end
end

OmniAuth.config.allowed_request_methods = [ :post ]
OmniAuth.config.silence_get_warning = true
