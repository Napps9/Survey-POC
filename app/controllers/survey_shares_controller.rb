class SurveySharesController < ApplicationController
  before_action :require_creator_org!
  before_action :require_admin!, only: [:create, :destroy]
  before_action :set_survey

  def index
    @alliances = current_organisation.alliances.active.includes(:partner_organisation)
    @shares    = @survey.survey_shares.includes(alliance: :partner_organisation)
  end

  def create
    alliance = current_organisation.alliances.find(params[:alliance_id])
    @survey.survey_shares.find_or_create_by!(alliance: alliance)
    redirect_to survey_shares_path(@survey), notice: "Partner share created."
  end

  def destroy
    share = @survey.survey_shares.find(params[:id])
    share.destroy!
    redirect_to survey_shares_path(@survey), notice: "Partner share removed."
  end

  private

  def set_survey
    @survey = current_organisation.surveys.find(params[:survey_id])
  end
end
