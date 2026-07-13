class PartnershipMembershipsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!
  before_action :load_partnership

  def destroy
    membership = @partnership.partnership_memberships.find(params[:id])
    org_name = membership.organisation.name
    membership.destroy!
    redirect_to partnership_path(@partnership), notice: "#{org_name} removed from #{@partnership.name}."
  end

  private

  def load_partnership
    @partnership = current_organisation.partnerships.find_by(id: params[:partnership_id])
    redirect_to partnerships_path, alert: "Partnership not found." unless @partnership
  end
end
