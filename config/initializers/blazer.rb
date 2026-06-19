# Blazer's UI is a client-side Vue.js app: its views ship {{ … }} expressions
# that Vue's runtime compiler evaluates via new Function(), which a browser only
# permits when the page's Content-Security-Policy allows 'unsafe-eval' in
# script-src.
#
# The app-wide policy (config/initializers/content_security_policy.rb) grants
# 'unsafe-eval' in development only, so in production Blazer's JavaScript is
# blocked, its v-cloak content never un-hides, and staff just see a blank page.
#
# Fix: give Blazer's own responses a dedicated CSP. Blazer is mounted behind the
# BLAZER_STAFF_EMAILS allowlist (config/routes.rb), so this is scoped to
# authenticated VertoNow staff on /blazer; every other route keeps the strict
# app-wide policy.
#
# We set the response header directly rather than going through Rails'
# per-controller `content_security_policy` macro: that macro shallow-clones and
# mutates the shared global policy object, which leaks 'unsafe-eval' into every
# other request in the process. Setting the header here is per-response and
# leak-free — and the CSP middleware leaves an already-present header untouched.
Rails.application.config.to_prepare do
  blazer_csp = [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "frame-ancestors 'self'",
    "form-action 'self'",
    "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self' data:",
    "img-src 'self' data:",
    "connect-src 'self'"
  ].join("; ").freeze

  Blazer::BaseController.after_action do
    response.headers["Content-Security-Policy"] = blazer_csp
  end
end
