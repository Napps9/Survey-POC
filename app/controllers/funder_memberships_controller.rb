class FunderMembershipsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!
  before_action :load_funder

  def update
    membership = @funder.funder_memberships.find(params[:id])
    if params[:status] == "suspended"
      membership.suspend!
      redirect_to funder_path(@funder), notice: t("funders.membership_suspended", org: membership.organisation.name)
    else
      membership.reactivate!
      redirect_to funder_path(@funder), notice: t("funders.membership_reactivated", org: membership.organisation.name)
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to funder_path(@funder), alert: e.record.errors.full_messages.first
  end

  private

  def load_funder
    @funder = current_organisation.funders.find_by(id: params[:funder_id])
    redirect_to funders_path, alert: t("funders.not_found") unless @funder
  end
end
