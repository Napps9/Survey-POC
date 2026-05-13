class AllianceVertosController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"

  before_action :set_share, only: [:show]

  def index
    @shares = SurveyShare
                .joins(:alliance)
                .where(alliances: { partner_organisation_id: current_organisation.id, status: "active" })
                .includes(survey: :organisation)
                .order(created_at: :desc)
  end

  def show
    @survey = @share.survey
    base    = @survey.responses.where(status: "completed")
    mine    = base.where(survey_share_id: @share.id)

    @mine_total       = mine.count
    @aggregate_total  = base.count
    @mine_results      = aggregate_results(Array(@survey.cards), mine)
    @aggregate_results = aggregate_results(Array(@survey.cards), base)
  end

  private

  def set_share
    @share = SurveyShare
               .joins(:alliance)
               .where(alliances: { partner_organisation_id: current_organisation.id, status: "active" })
               .find(params[:id])
  end
end
