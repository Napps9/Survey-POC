class PartnershipVertosController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"

  before_action :load_partnership
  before_action :require_creator_admin!, only: [ :create, :destroy ]

  def create
    survey = current_organisation.surveys.kept.find(params[:survey_id])
    @partnership.partnership_vertos.find_or_create_by!(survey_id: survey.id)
    PartnershipShareSync.ensure_shares_for(partnership: @partnership)
    redirect_to partnership_path(@partnership), notice: "Added \"#{survey.title.presence || 'Verto'}\" to #{@partnership.name}."
  end

  def destroy
    av = @partnership.partnership_vertos.find(params[:id])
    av.destroy!
    redirect_to partnership_path(@partnership), notice: "Verto removed from #{@partnership.name}."
  end

  def show
    @partnership_verto = @partnership.partnership_vertos.find(params[:id])
    @survey = @partnership_verto.survey

    @share = @partnership_verto.survey_shares.find_by(partner_organisation_id: current_organisation.id)
    unless @share
      redirect_to partnership_path(@partnership), alert: "No share link for this Verto."
      return
    end

    partnership_share_ids = @partnership_verto.survey_shares.pluck(:id)
    completed = @survey.responses.where(status: "completed")
    mine      = completed.where(survey_share_id: @share.id)
    partnership_completed = completed.where(survey_share_id: partnership_share_ids)

    @mine_total       = mine.count
    @aggregate_total  = partnership_completed.count
    @mine_results      = aggregate_results(Array(@survey.cards), mine)
    @aggregate_results = aggregate_results(Array(@survey.cards), partnership_completed)
  end

  private

  def load_partnership
    @partnership = Partnership.find_by(id: params[:partnership_id])
    unless @partnership && (
      @partnership.organisation_id == current_organisation.id ||
      @partnership.partnership_memberships.active.exists?(organisation_id: current_organisation.id)
    )
      redirect_to partnerships_path, alert: "Partnership not found."
    end
  end

  def require_creator_admin!
    return if @partnership.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to partnership_path(@partnership), alert: "Only the partnership creator can do that."
  end
end
