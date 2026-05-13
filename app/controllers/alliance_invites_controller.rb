class AllianceInvitesController < ApplicationController
  layout "fullscreen"
  before_action :require_creator_org!
  before_action :require_admin!

  def new
  end

  def create
    @invite = current_organisation.invites.create!(
      email_address: nil,
      role:          "admin",
      kind:          "partner",
      invited_by:    Current.user,
      expires_at:    14.days.from_now
    )
  end
end
