class AllianceMembershipsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!
  before_action :load_alliance

  def destroy
    membership = @alliance.alliance_memberships.find(params[:id])
    org_name = membership.organisation.name
    membership.destroy!
    redirect_to alliance_path(@alliance), notice: "#{org_name} removed from #{@alliance.name}."
  end

  private

  def load_alliance
    @alliance = current_organisation.alliances.find_by(id: params[:alliance_id])
    redirect_to alliances_path, alert: "Alliance not found." unless @alliance
  end
end
