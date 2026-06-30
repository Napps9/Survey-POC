# Be sure to restart your server when you modify this file.

# Content Security Policy — pragmatic, enforcing.
#
# script-src deliberately keeps 'unsafe_inline' because the dashboard/editor use
# many inline event handlers (onclick/onmouseover/onchange across ~12 views) and
# a few inline <script> blocks; a nonce-based policy would require refactoring
# every one of those first. Even so, this still meaningfully hardens the app:
# only same-origin (and one analytics vendor) scripts may load, no plugins,
# no foreign framing, and forms/connections are restricted.
#
# Path to a stronger policy: refactor inline on*= handlers to Stimulus/CSS, then
# switch script_src to :self + a nonce (config.content_security_policy_nonce_*).
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src      :self
    policy.base_uri         :self
    policy.object_src       :none
    policy.form_action      :self
    policy.frame_ancestors  :self # matches the existing X-Frame-Options: SAMEORIGIN

    # Inline scripts/handlers stay allowed. External scripts are limited to
    # Microsoft Clarity (its inline loader injects a tag from www.clarity.ms).
    # 'unsafe_eval' is added in development only, for web-console's REPL.
    script_src = [ :self, :unsafe_inline, "https://www.clarity.ms", "https://*.clarity.ms" ]
    script_src << :unsafe_eval if Rails.env.development?
    policy.script_src(*script_src)

    # Inline styles are used throughout the app; Google Fonts CSS is external.
    policy.style_src  :self, :unsafe_inline, "https://fonts.googleapis.com"
    policy.font_src   :self, :data, "https://fonts.gstatic.com"

    # App assets + Active Storage logos (self), survey background data: URLs,
    # Pexels stock photos (editor media picker + auto-populated Verto imagery,
    # served from the Pexels image CDN), and Clarity's tracking pixels.
    policy.img_src    :self, :data, "https://images.pexels.com", "https://*.clarity.ms"

    # Pexels stock videos stream from the Pexels video CDN (autoplaying card
    # art). Without this the browser blocks the <video>, like img_src did for
    # photos. If clips ever come from another host, add it here.
    policy.media_src  :self, "https://videos.pexels.com"

    # XHR/fetch: same-origin app endpoints plus Clarity's upload endpoints.
    policy.connect_src :self, "https://*.clarity.ms", "https://c.bing.com"

    policy.worker_src   :self
    policy.manifest_src :self
  end
end
