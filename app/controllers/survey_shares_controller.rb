class SurveySharesController < ApplicationController
  layout "fullscreen"
  before_action :require_creator_org!
  before_action :require_admin!, only: [:create, :destroy]
  before_action :set_survey

  def index
    @alliances = current_organisation.alliances.active.includes(:partner_organisation)
    @shares    = @survey.survey_shares.includes(alliance: :partner_organisation).order(:created_at)
  end

  def create
    alliance = current_organisation.alliances.active.find_by(id: params[:alliance_id])
    if alliance.nil?
      redirect_back fallback_location: survey_path(@survey),
                    alert: "Select a partner organisation first."
      return
    end

    @survey.survey_shares.find_or_create_by!(alliance: alliance)
    redirect_back fallback_location: survey_path(@survey),
                  notice: "Partner link generated for #{alliance.partner_organisation.name}."
  end

  def destroy
    share = @survey.survey_shares.find(params[:id])
    share.destroy!
    redirect_back fallback_location: survey_path(@survey),
                  notice: "Partner link removed."
  end

  private

  def set_survey
    @survey = current_organisation.surveys.find(params[:survey_id])
  end
end
