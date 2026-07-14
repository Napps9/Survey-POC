class PartnershipsController < ApplicationController
  include AggregatesSurveyResults
  layout "fullscreen"

  before_action :require_admin!, only: [ :new, :create, :destroy ]
  before_action :load_partnership, only: [ :show, :destroy ]
  before_action :require_creator_ownership!, only: [ :destroy ]

  def index
    @owned_partnerships    = current_organisation.partnerships
                           .includes(:member_organisations).order(created_at: :desc)
    @member_partnerships   = current_organisation.member_partnerships
                           .where(partnership_memberships: { status: "active" })
                           .includes(:organisation, :member_organisations)
                           .order("partnerships.created_at desc")

    owned_ids = @owned_partnerships.map(&:id)
    if owned_ids.any?
      @verto_counts_by_partnership    = PartnershipVerto.where(partnership_id: owned_ids).group(:partnership_id).count
      @response_counts_by_partnership = Response
                                       .joins(survey_share: :partnership_verto)
                                       .where(partnership_vertos: { partnership_id: owned_ids })
                                       .group("partnership_vertos.partnership_id")
                                       .count
      @member_counts_by_partnership   = PartnershipMembership.active.where(partnership_id: owned_ids).group(:partnership_id).count
    else
      @verto_counts_by_partnership    = {}
      @response_counts_by_partnership = {}
      @member_counts_by_partnership   = {}
    end

    # Header stat strip — summed from the per-partnership hashes above.
    @total_partners           = @member_counts_by_partnership.values.sum
    @total_shared_vertos      = @verto_counts_by_partnership.values.sum
    @total_partnership_responses = @response_counts_by_partnership.values.sum
  end

  def new
    @partnership = current_organisation.partnerships.new
  end

  def create
    @partnership = current_organisation.partnerships.new(partnership_params)
    if @partnership.save
      redirect_to partnership_path(@partnership), notice: "Partnership \"#{@partnership.name}\" created."
    else
      flash.now[:alert] = @partnership.errors.full_messages.first
      render :new, status: :unprocessable_entity
    end
  end

  def show
    if @partnership.organisation_id == current_organisation.id
      load_creator_show_data
      render :creator_show
    else
      load_partner_show_data
      render :partner_show
    end
  end

  def destroy
    @partnership.destroy!
    redirect_to partnerships_path, notice: "Partnership removed."
  end

  private

  def load_partnership
    @partnership = Partnership.find_by(id: params[:id])
    unless @partnership && (
      @partnership.organisation_id == current_organisation.id ||
      @partnership.partnership_memberships.active.exists?(organisation_id: current_organisation.id)
    )
      redirect_to partnerships_path, alert: "Partnership not found." and return
    end
  end

  def require_creator_ownership!
    return if @partnership.organisation_id == current_organisation.id
    redirect_to partnerships_path, alert: "Only the partnership creator can do that."
  end

  def partnership_params
    params.require(:partnership).permit(:name)
  end

  def load_creator_show_data
    @memberships = @partnership.partnership_memberships.includes(organisation: { memberships: :user }).order(:created_at)
    @partnership_vertos = @partnership.partnership_vertos.includes(:survey).order(:created_at)

    av_ids = @partnership_vertos.map(&:id)
    @shares_by_verto = if av_ids.any?
      @partnership.survey_shares.includes(:partner_organisation).group_by(&:partnership_verto_id)
    else
      {}
    end

    share_ids = @shares_by_verto.values.flatten.map(&:id)
    @response_counts_by_share = share_ids.any? ?
      Response.where(survey_share_id: share_ids).group(:survey_share_id).count : {}
    @completed_counts_by_share = share_ids.any? ?
      Response.where(survey_share_id: share_ids, status: "completed").group(:survey_share_id).count : {}

    # Header stat strip.
    @total_responses = @response_counts_by_share.values.sum
    total_completed  = @completed_counts_by_share.values.sum
    @completion_rate = @total_responses.positive? ? ((total_completed.to_f / @total_responses) * 100).round : nil

    @available_surveys = current_organisation.surveys.kept
                           .where.not(id: @partnership_vertos.map(&:survey_id))
                           .where.not(publish_token: nil)
                           .order(updated_at: :desc)

    @partnership_sets  = shared_question_sets
    @available_sets = current_organisation.common_question_sets.kept
                        .where.not(id: @partnership_sets.map(&:common_question_set_id))
                        .order(:name)
  end

  def load_partner_show_data
    @other_members = @partnership.member_organisations
                       .where.not(id: current_organisation.id)
                       .where(partnership_memberships: { status: "active" })
                       .distinct
    @total_partner_count = @partnership.partnership_memberships.active.count

    @partnership_vertos = @partnership.partnership_vertos.includes(:survey).order(:created_at)
    @my_shares_by_verto = @partnership.survey_shares
                            .where(partner_organisation_id: current_organisation.id)
                            .index_by(&:partnership_verto_id)

    @partnership_sets = shared_question_sets
  end

  # Question sets shared into this partnership, skipping any the owner has since
  # archived — partners shouldn't keep seeing a deleted set's questions.
  def shared_question_sets
    @partnership.partnership_common_question_sets
             .includes(common_question_set: :common_questions)
             .order(:created_at)
             .select { |acs| acs.common_question_set.deleted_at.nil? }
  end
end
