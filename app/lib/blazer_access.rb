# Access control for the internal Blazer BI tool, mounted at /blazer.
#
# Blazer exposes read-only SQL over the WHOLE application database (every org's
# usage and collected responses), so it is for VertoNow staff only — never
# customers. Access is gated by an explicit allowlist of staff email addresses
# in BLAZER_STAFF_EMAILS (comma/space separated) and is DENY-BY-DEFAULT: when
# the variable is unset, nobody gets in.
#
# Used both as a routing constraint (config/routes.rb) and to attribute Blazer's
# audit log to the acting user (config/initializers/blazer.rb).
module BlazerAccess
  module_function

  # Downcased staff allowlist from the environment. Empty (deny-all) when unset.
  def staff_emails
    ENV.fetch("BLAZER_STAFF_EMAILS", "").downcase.split(/[\s,]+/).reject(&:blank?)
  end

  def staff?(user)
    return false if user.nil?

    email = user.email_address.to_s.downcase
    email.present? && staff_emails.include?(email)
  end

  # The signed-in User for a request, read from the same signed session cookie
  # the app's Authentication concern issues. Returns nil when not signed in.
  def user_for(request)
    session_id = request.cookie_jar.signed[:session_id]
    return nil if session_id.blank?

    Session.find_by(id: session_id)&.user
  end

  # Routing-constraint predicate: only staff requests match the Blazer mount.
  # A non-match means the route simply isn't there (404) for everyone else.
  def staff_request?(request)
    staff?(user_for(request))
  end
end
