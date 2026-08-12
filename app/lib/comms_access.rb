# Access control for Comms — the email campaign builder and scheduler.
#
# Comms can address the WHOLE platform user base plus imported contact lists,
# so it is a Playverto-staff surface, never a customer one. The gate is
# membership of the Playverto organisation itself (slug "playverto"), which
# encodes the requirement exactly — the owner and the members of the
# Playverto org — with nothing to configure, and is DENY-BY-DEFAULT: no
# session, no membership, no access.
#
# Used as a routing constraint (config/routes.rb — a non-member gets a 404,
# not a 403, because the existence of an internal mass-mail surface is
# itself something customers have no reason to learn), as a before_action in
# Comms::BaseController, and by the nav/palette predicates.
module CommsAccess
  module_function

  PLAYVERTO_SLUG = "playverto"

  def allowed?(user)
    return false if user.nil?

    Membership.joins(:organisation)
              .where(user_id: user.id, organisations: { slug: PLAYVERTO_SLUG })
              .exists?
  end

  # Routing-constraint predicate; resolves the user from the same signed
  # session cookie the app's Authentication concern issues (BlazerAccess
  # already knows how).
  def allowed_request?(request)
    allowed?(BlazerAccess.user_for(request))
  end
end
