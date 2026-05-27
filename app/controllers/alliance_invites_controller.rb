class AllianceInvitesController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!

  def create
    alliance = current_organisation.alliances.find(params[:alliance_id])
    invite = current_organisation.invites.create!(
      email_address: "link-#{SecureRandom.hex(8)}@partner.invite",
      role:          "admin",
      kind:          "partner",
      alliance:      alliance,
      invited_by:    Current.user,
      expires_at:    14.days.from_now
    )
    redirect_to alliance_path(alliance, new_invite_token: invite.token)
  end
end
