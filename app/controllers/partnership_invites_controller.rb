class PartnershipInvitesController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!

  def create
    partnership = current_organisation.partnerships.find(params[:partnership_id])
    invite = current_organisation.invites.create!(
      email_address: "link-#{SecureRandom.hex(8)}@partner.invite",
      role:          "admin",
      kind:          "partner",
      partnership:      partnership,
      invited_by:    Current.user,
      expires_at:    14.days.from_now
    )
    redirect_to partnership_path(partnership, new_invite_token: invite.token)
  end
end
