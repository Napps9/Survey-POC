# Access control for the Ask Verto chat (/ask and its thread/message routes).
#
# The chat is gated by an allowlist of user email addresses in
# ASK_VERTO_USER_EMAILS (comma/space separated). Unlike BlazerAccess this is
# OPEN-WHEN-UNSET: with no variable the feature behaves as it always has —
# available to every signed-in account. That keeps dev, test and CI (where the
# variable is never set) exercising the real feature; the restriction engages
# only where someone has deliberately set the list, i.e. production.
#
# This gates the CHAT only — who may ask questions of the shared corpus. The
# consent flow that feeds the corpus (offering a Verto, the editor block, the
# dashboard badges) is untouched: partners can keep contributing data even
# while the asking side is limited to the allowlist.
module AskVertoAccess
  module_function

  # Downcased allowlist from the environment. Empty (no restriction) when unset.
  def allowed_emails
    ENV.fetch("ASK_VERTO_USER_EMAILS", "").downcase.split(/[\s,]+/).reject(&:blank?)
  end

  def allowed?(user)
    emails = allowed_emails
    return true if emails.empty?
    return false if user.nil?

    email = user.email_address.to_s.downcase
    email.present? && emails.include?(email)
  end
end
