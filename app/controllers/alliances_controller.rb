class AlliancesController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"

  before_action :require_admin!, only: [ :new, :create, :destroy ]
  before_action :load_alliance, only: [ :show, :destroy ]
  before_action :require_creator_ownership!, only: [ :destroy ]

  def index
    @owned_alliances    = current_organisation.alliances
                           .includes(:member_organisations).order(created_at: :desc)
    @member_alliances   = current_organisation.member_alliances
                           .where(alliance_memberships: { status: "active" })
                           .includes(:organisation, :member_organisations)
                           .order("alliances.created_at desc")

    owned_ids = @owned_alliances.map(&:id)
    if owned_ids.any?
      @verto_counts_by_alliance    = AllianceVerto.where(alliance_id: owned_ids).group(:alliance_id).count
      @response_counts_by_alliance = Response
                                       .joins(survey_share: :alliance_verto)
                                       .where(alliance_vertos: { alliance_id: owned_ids })
                                       .group("alliance_vertos.alliance_id")
                                       .count
      @member_counts_by_alliance   = AllianceMembership.active.where(alliance_id: owned_ids).group(:alliance_id).count
    else
      @verto_counts_by_alliance    = {}
      @response_counts_by_alliance = {}
      @member_counts_by_alliance   = {}
    end
  end

  def new
    @alliance = current_organisation.alliances.new
  end

  def create
    @alliance = current_organisation.alliances.new(alliance_params)
    if @alliance.save
      redirect_to alliance_path(@alliance), notice: "Alliance \"#{@alliance.name}\" created."
    else
      flash.now[:alert] = @alliance.errors.full_messages.first
      render :new, status: :unprocessable_entity
    end
  end

  def show
    if @alliance.organisation_id == current_organisation.id
      load_creator_show_data
      render :creator_show
    else
      load_partner_show_data
      render :partner_show
    end
  end

  def destroy
    @alliance.destroy!
    redirect_to alliances_path, notice: "Alliance removed."
  end

  private

  def load_alliance
    @alliance = Alliance.find_by(id: params[:id])
    unless @alliance && (
      @alliance.organisation_id == current_organisation.id ||
      @alliance.alliance_memberships.active.exists?(organisation_id: current_organisation.id)
    )
      redirect_to alliances_path, alert: "Alliance not found." and return
    end
  end

  def require_creator_ownership!
    return if @alliance.organisation_id == current_organisation.id
    redirect_to alliances_path, alert: "Only the alliance creator can do that."
  end

  def alliance_params
    params.require(:alliance).permit(:name)
  end

  def load_creator_show_data
    @memberships = @alliance.alliance_memberships.includes(:organisation).order(:created_at)
    @alliance_vertos = @alliance.alliance_vertos.includes(:survey).order(:created_at)

    av_ids = @alliance_vertos.map(&:id)
    @shares_by_verto = if av_ids.any?
      @alliance.survey_shares.includes(:partner_organisation).group_by(&:alliance_verto_id)
    else
      {}
    end

    share_ids = @shares_by_verto.values.flatten.map(&:id)
    @response_counts_by_share = share_ids.any? ?
      Response.where(survey_share_id: share_ids).group(:survey_share_id).count : {}
    @completed_counts_by_share = share_ids.any? ?
      Response.where(survey_share_id: share_ids, status: "completed").group(:survey_share_id).count : {}

    @available_surveys = current_organisation.surveys.kept
                           .where.not(id: @alliance_vertos.map(&:survey_id))
                           .where.not(publish_token: nil)
                           .order(updated_at: :desc)
  end

  def load_partner_show_data
    @other_members = @alliance.member_organisations
                       .where.not(id: current_organisation.id)
                       .where(alliance_memberships: { status: "active" })
                       .distinct
    @total_partner_count = @alliance.alliance_memberships.active.count

    @alliance_vertos = @alliance.alliance_vertos.includes(:survey).order(:created_at)
    @my_shares_by_verto = @alliance.survey_shares
                            .where(partner_organisation_id: current_organisation.id)
                            .index_by(&:alliance_verto_id)
  end
end
