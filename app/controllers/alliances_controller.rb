class AlliancesController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"
  before_action :require_creator_org!
  before_action :require_admin!, only: [ :destroy ]
  before_action :set_alliance,   only: [ :show ]

  def index
    @alliances = current_organisation.alliances.includes(:partner_organisation).order(created_at: :desc)

    @total_vertos      = current_organisation.surveys.kept.count
    @partner_responses = Response
                          .joins(survey_share: :alliance)
                          .where(alliances: { organisation_id: current_organisation.id })
                          .count
    @partner_completed = Response
                          .joins(survey_share: :alliance)
                          .where(alliances: { organisation_id: current_organisation.id }, status: "completed")
                          .count
    @completion_rate = @partner_responses.positive? ? ((@partner_completed.to_f / @partner_responses) * 100).round : nil

    @verto_counts_by_alliance    = SurveyShare.where(alliance_id: @alliances.map(&:id)).group(:alliance_id).count
    @response_counts_by_alliance = Response.joins(:survey_share)
                                           .where(survey_shares: { alliance_id: @alliances.map(&:id) })
                                           .group("survey_shares.alliance_id")
                                           .count
  end

  def show
    @shares = @alliance.survey_shares.includes(:survey).order(created_at: :desc)
    share_ids         = @shares.map(&:id)
    shared_survey_ids = @shares.map(&:survey_id)

    @share_response_counts  = Response.where(survey_share_id: share_ids).group(:survey_share_id).count
    @share_completed_counts = Response.where(survey_share_id: share_ids, status: "completed").group(:survey_share_id).count
    @survey_total_responses = shared_survey_ids.any? ? Response.where(survey_id: shared_survey_ids).group(:survey_id).count : {}

    @total_partner_responses = @share_response_counts.values.sum
    @total_partner_completed = @share_completed_counts.values.sum
    @total_respondents       = @survey_total_responses.values.sum
    @completion_rate = @total_partner_responses.positive? ? ((@total_partner_completed.to_f / @total_partner_responses) * 100).round : nil

    @available_surveys = current_organisation.surveys.kept
                           .where.not(id: shared_survey_ids)
                           .where.not(publish_token: nil)
                           .order(updated_at: :desc)
  end

  def destroy
    alliance = current_organisation.alliances.find(params[:id])
    alliance.destroy!
    redirect_to alliances_path, notice: "Partner removed."
  end

  private

  def set_alliance
    @alliance = current_organisation.alliances.includes(:partner_organisation).find(params[:id])
  end
end
