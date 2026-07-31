class PartnershipMembershipsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!
  before_action :load_partnership

  def destroy
    membership = @partnership.partnership_memberships.find(params[:id])
    org_name = membership.organisation.name
    membership.destroy!
    redirect_to partnership_path(@partnership), notice: t("flash.partnership_memberships.organisation_removed", org: org_name, partnership: @partnership.name)
  end

  private

  def load_partnership
    @partnership = current_organisation.partnerships.find_by(id: params[:partnership_id])
    redirect_to partnerships_path, alert: t("flash.partnership_memberships.partnership_not_found") unless @partnership
  end
end
