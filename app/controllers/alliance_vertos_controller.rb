class AllianceVertosController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"

  before_action :load_alliance
  before_action :require_creator_admin!, only: [ :create, :destroy ]

  def create
    survey = current_organisation.surveys.kept.find(params[:survey_id])
    @alliance.alliance_vertos.find_or_create_by!(survey_id: survey.id)
    AllianceShareSync.ensure_shares_for(alliance: @alliance)
    redirect_to alliance_path(@alliance), notice: "Added \"#{survey.title.presence || 'Verto'}\" to #{@alliance.name}."
  end

  def destroy
    av = @alliance.alliance_vertos.find(params[:id])
    av.destroy!
    redirect_to alliance_path(@alliance), notice: "Verto removed from #{@alliance.name}."
  end

  def show
    @alliance_verto = @alliance.alliance_vertos.find(params[:id])
    @survey = @alliance_verto.survey

    @share = @alliance_verto.survey_shares.find_by(partner_organisation_id: current_organisation.id)
    unless @share
      redirect_to alliance_path(@alliance), alert: "No share link for this Verto."
      return
    end

    alliance_share_ids = @alliance_verto.survey_shares.pluck(:id)
    completed = @survey.responses.where(status: "completed")
    mine      = completed.where(survey_share_id: @share.id)
    alliance_completed = completed.where(survey_share_id: alliance_share_ids)

    @mine_total       = mine.count
    @aggregate_total  = alliance_completed.count
    @mine_results      = aggregate_results(Array(@survey.cards), mine)
    @aggregate_results = aggregate_results(Array(@survey.cards), alliance_completed)
  end

  private

  def load_alliance
    @alliance = Alliance.find_by(id: params[:alliance_id])
    unless @alliance && (
      @alliance.organisation_id == current_organisation.id ||
      @alliance.alliance_memberships.active.exists?(organisation_id: current_organisation.id)
    )
      redirect_to alliances_path, alert: "Alliance not found."
    end
  end

  def require_creator_admin!
    return if @alliance.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to alliance_path(@alliance), alert: "Only the alliance creator can do that."
  end
end
