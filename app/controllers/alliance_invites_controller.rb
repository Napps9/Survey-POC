class AllianceInvitesController < ApplicationController
  layout "fullscreen"
  before_action :require_creator_org!
  before_action :require_admin!

  def create
    invite = current_organisation.invites.create!(
      email_address: "link-#{SecureRandom.hex(8)}@partner.invite",
      role:          "admin",
      kind:          "partner",
      invited_by:    Current.user,
      expires_at:    14.days.from_now
    )
    redirect_to alliances_path(new_invite_token: invite.token)
  end
end
