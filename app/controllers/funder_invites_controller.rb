class FunderInvitesController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!
  before_action :load_funder

  def create
    unless @funder.seats_available?
      return redirect_to funder_path(@funder), alert: t("funders.no_seats_available")
    end

    invite = current_organisation.invites.create!(
      email_address: "link-#{SecureRandom.hex(8)}@funder.invite",
      role:          "admin",
      kind:          "licensee",
      funder:        @funder,
      invited_by:    Current.user,
      expires_at:    14.days.from_now
    )
    redirect_to funder_path(@funder, new_invite_token: invite.token)
  end

  private

  def load_funder
    @funder = current_organisation.funders.find(params[:funder_id])
  end
end
