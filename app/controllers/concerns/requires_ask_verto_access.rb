# 404s the Ask Verto chat for signed-in users outside the ASK_VERTO_USER_EMAILS
# allowlist (no-op while the list is unset — see AskVertoAccess). A 404 rather
# than a 403 for the same reason as the Blazer mount: for everyone off the
# list the surface simply isn't there, matching the hidden nav entries.
module RequiresAskVertoAccess
  extend ActiveSupport::Concern

  included do
    before_action :require_ask_verto_access
  end

  private

  def require_ask_verto_access
    raise ActiveRecord::RecordNotFound unless AskVertoAccess.allowed?(Current.user)
  end
end
