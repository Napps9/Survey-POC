# Who may edit a Verto that Survey#editing_locked? says is frozen.
#
# The lock exists for a real reason: answers are stored against card POSITION,
# so adding, removing or reordering cards on a Verto that is live (or has ever
# collected responses) silently re-points every answer already gathered. That
# is why every editor write path refuses a locked deck and the editor renders
# read-only. This module is the one deliberate exception — the accounts that
# may edit anyway, knowingly, with the editor warning them what it costs.
#
# Gated by an allowlist of user email addresses in LIVE_EDIT_USER_EMAILS
# (comma/space separated), the BlazerAccess shape. Unlike Blazer it has a
# DEFAULT: the owner asked for this capability for their own account by name
# (2026-09-02), and a grant that only takes effect once someone remembers to
# set a variable on Render is a grant that ships switched off. Setting the
# variable replaces the default outright — widen it to more addresses, or set
# it to an empty value to switch the override off for everyone.
#
# The address must be a PROVEN one (User#email_verified?). Sign-up is open and
# takes any address, so in a database where the owner's row doesn't yet exist
# — a fresh environment, a restored staging copy — a default that matched on
# the address alone could be claimed by whoever registered it first. Blazer and
# Ask Verto don't need this: Blazer denies until a deployer fills its list, Ask
# Verto opens to every signed-in account until one narrows it, and neither ever
# grants a specific address nobody set. This one does, so it asks for the same
# proof publishing does (P0-8): the mailbox.
#
# This is a PERMISSION, not a change to the lock itself: Survey#editing_locked?
# still answers what it always did, the model's own guards (the primary-
# language switch, the normalisers that skip locked decks) are untouched, and
# organisation scoping is unchanged — an allowed account edits the Vertos it
# can already see, not everyone's. The override is applied at the
# controller/view boundary by the LiveEditing concern, the same place
# OrganisationScope enforces Verto creation.
module LiveEditAccess
  module_function

  DEFAULT_EMAILS = "nick@playverto.com"

  # Downcased allowlist: the environment's, else the default above.
  def allowed_emails
    ENV.fetch("LIVE_EDIT_USER_EMAILS", DEFAULT_EMAILS).downcase.split(/[\s,]+/).reject(&:blank?)
  end

  def allowed?(user)
    return false if user.nil?
    return false unless user.email_verified?

    email = user.email_address.to_s.downcase
    email.present? && allowed_emails.include?(email)
  end
end
