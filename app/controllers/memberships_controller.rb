class MembershipsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!

  def index
    @memberships      = current_organisation.memberships.includes(:user).order("users.name")
    @pending_invites  = current_organisation.invites.pending.includes(:invited_by).order(created_at: :desc)
  end

  def destroy
    membership = current_organisation.memberships.find(params[:id])
    if membership.user == Current.user
      redirect_to organisation_memberships_path(current_organisation), alert: t("flash.memberships.cannot_remove_self")
    else
      membership.destroy
      redirect_to organisation_memberships_path(current_organisation), notice: t("flash.memberships.member_removed")
    end
  end
end
