# Access control for Comms — the email campaign builder and scheduler.
#
# Comms can address the WHOLE platform user base plus imported contact lists,
# so it is a Playverto-staff surface, never a customer one. "Staff" is
# membership of the Playverto organisation itself — see PlayvertoStaff, which
# owns that predicate now that a second caller (the Verto-creation gate) needs
# it too. Deny-by-default: no session, no membership, no access.
#
# Used as a routing constraint (config/routes.rb — a non-member gets a 404,
# not a 403, because the existence of an internal mass-mail surface is
# itself something customers have no reason to learn), as a before_action in
# Comms::BaseController, and by the nav/palette predicates.
module CommsAccess
  module_function

  # Kept as a constant because db/migrate/20260812160000_grant_comms_access_to_owner.rb
  # references it by name, and a shipped migration must keep running.
  PLAYVERTO_SLUG = PlayvertoStaff::SLUG

  def allowed?(user)
    PlayvertoStaff.member?(user)
  end

  # Routing-constraint predicate; resolves the user from the same signed
  # session cookie the app's Authentication concern issues (BlazerAccess
  # already knows how).
  def allowed_request?(request)
    allowed?(BlazerAccess.user_for(request))
  end
end
