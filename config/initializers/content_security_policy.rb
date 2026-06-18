# Be sure to restart your server when you modify this file.

# Content Security Policy — enforcing, nonce-based.
#
# Inline <script> tags carry a per-request nonce (importmap, i18n, analytics);
# there are no inline on*= event handlers (they were refactored to Stimulus/CSS),
# so script-src can omit 'unsafe-inline'. style-src keeps 'unsafe-inline' because
# the app uses inline style="" pervasively (style injection is low risk and not
# nonced here). External origins are limited to the resources the app actually
# loads: Google Fonts and Microsoft Clarity.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src      :self
    policy.base_uri         :self
    policy.object_src       :none
    policy.form_action      :self
    policy.frame_ancestors  :self # matches the existing X-Frame-Options: SAMEORIGIN

    # Inline scripts are allowed only via the per-request nonce (below). External
    # scripts are limited to Microsoft Clarity (its nonced inline loader injects a
    # tag from www.clarity.ms). 'unsafe_eval' is added in development only, for
    # web-console's REPL on error pages.
    script_src = [ :self, "https://www.clarity.ms", "https://*.clarity.ms" ]
    script_src << :unsafe_eval if Rails.env.development?
    policy.script_src(*script_src)

    # Inline styles are used throughout the app; Google Fonts CSS is external.
    policy.style_src  :self, :unsafe_inline, "https://fonts.googleapis.com"
    policy.font_src   :self, :data, "https://fonts.gstatic.com"

    # App assets + Active Storage logos (self), survey background data: URLs,
    # and Clarity's tracking pixels.
    policy.img_src    :self, :data, "https://*.clarity.ms"

    # XHR/fetch: same-origin app endpoints plus Clarity's upload endpoints.
    policy.connect_src :self, "https://*.clarity.ms", "https://c.bing.com"

    policy.worker_src   :self
    policy.manifest_src :self
  end

  # A fresh nonce per request, applied to script-src (not style-src, which keeps
  # 'unsafe-inline'). SecureRandom — not the session id — so it's always present,
  # including on pages without a session such as the public /play player.
  config.content_security_policy_nonce_generator  = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives  = %w[ script-src ]
end
