class AlliancesController < ApplicationController
  layout "fullscreen"
  before_action :require_creator_org!
  before_action :require_admin!, only: [:destroy]

  def index
    @alliances = current_organisation.alliances.includes(:partner_organisation).order(created_at: :desc)
  end

  def destroy
    alliance = current_organisation.alliances.find(params[:id])
    alliance.destroy!
    redirect_to alliances_path, notice: "Partner removed."
  end
end
