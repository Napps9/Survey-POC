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
    if params[:alliance_id].present?
      alliance = current_organisation.alliances.find(params[:alliance_id])
      @survey.survey_shares.find_or_create_by!(alliance: alliance)
    else
      label = params[:label].to_s.strip.presence ||
              "Partner link ##{@survey.survey_shares.where(alliance_id: nil).count + 1}"
      @survey.survey_shares.create!(alliance: nil, label: label)
    end

    redirect_back fallback_location: survey_shares_path(@survey),
                  notice: "Partner link generated."
  end

  def destroy
    share = @survey.survey_shares.find(params[:id])
    share.destroy!
    redirect_back fallback_location: survey_shares_path(@survey),
                  notice: "Partner link removed."
  end

  private

  def set_survey
    @survey = current_organisation.surveys.find(params[:survey_id])
  end
end
