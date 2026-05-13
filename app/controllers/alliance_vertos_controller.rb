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
    @scope = params[:scope].presence_in(%w[mine aggregate]) || "mine"
    base = @survey.responses.where(status: "completed")
    @responses = @scope == "mine" ? base.where(survey_share_id: @share.id) : base
    @total = @responses.count
    @aggregated = aggregate_results(Array(@survey.cards), @responses)
  end

  private

  def set_share
    @share = SurveyShare
               .joins(:alliance)
               .where(alliances: { partner_organisation_id: current_organisation.id, status: "active" })
               .find(params[:id])
  end
end
