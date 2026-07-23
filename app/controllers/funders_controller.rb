class FundersController < ApplicationController
  layout "fullscreen"

  before_action :require_admin!, only: [ :new, :create ]
  before_action :require_funder_access!, only: [ :index ]
  before_action :require_funder_enabled!, only: [ :new, :create ]
  before_action :load_funder, only: [ :show ]

  def index
    @owned_funders  = current_organisation.funders.order(created_at: :desc)
    @member_funders = current_organisation.member_funders
                        .where(funder_memberships: { status: "active" })
                        .includes(:organisation)
                        .order("funders.created_at desc")

    # An org that runs exactly one funder program has no real "list" to
    # browse — its Dashboard *is* that program's detail page. Send it there
    # directly instead of showing a list of one.
    if current_organisation.funder_enabled? && @owned_funders.one?
      redirect_to funder_path(@owned_funders.first) and return
    end

    owned_ids = @owned_funders.map(&:id)
    @active_counts_by_funder = owned_ids.any? ?
      FunderMembership.active.where(funder_id: owned_ids).group(:funder_id).count : {}
    @pending_invite_counts_by_funder = owned_ids.any? ?
      Invite.licensee.pending.where(funder_id: owned_ids).group(:funder_id).count : {}

    @total_seats    = @owned_funders.sum(&:seat_count)
    @total_assigned = @active_counts_by_funder.values.sum
    @total_available = [ @total_seats - @total_assigned - @pending_invite_counts_by_funder.values.sum, 0 ].max
  end

  def new
    @funder = current_organisation.funders.new
  end

  def create
    @funder = current_organisation.funders.new(funder_params)
    if @funder.save
      redirect_to funder_path(@funder), notice: t("funders.created", name: @funder.name)
    else
      flash.now[:alert] = @funder.errors.full_messages.first
      render :new, status: :unprocessable_entity
    end
  end

  def show
    if @funder.organisation_id == current_organisation.id
      load_creator_show_data
      render :creator_show
    else
      load_member_show_data
      render :member_show
    end
  end

  private

  # Funders is a staff-granted capability (Organisation#funder_enabled, set
  # via console/Blazer) rather than self-serve like Partnerships — but an
  # org licensed under someone else's funder still needs to see it.
  def require_funder_access!
    return if current_organisation.funder_enabled? || current_organisation.member_funders.exists?
    redirect_to root_path, alert: "Funders isn't available for your organisation yet."
  end

  def require_funder_enabled!
    return if current_organisation.funder_enabled?
    redirect_to root_path, alert: "Funders isn't available for your organisation yet."
  end

  def load_funder
    @funder = Funder.find_by(id: params[:id])
    unless @funder && (
      @funder.organisation_id == current_organisation.id ||
      @funder.funder_memberships.exists?(organisation_id: current_organisation.id)
    )
      redirect_to funders_path, alert: t("funders.not_found") and return
    end
  end

  # Sets the starting seat count when a funder program is first created.
  # Raising it later is a Playverto-side action (console/Blazer), not
  # something the org can self-serve — see creator_show.html.erb.
  def funder_params
    params.require(:funder).permit(:name, :seat_count)
  end

  def load_creator_show_data
    @memberships = @funder.funder_memberships.includes(organisation: { memberships: :user }).order(:created_at)
    # An invite that hasn't been accepted yet holds a seat with no organisation
    # attached — it's an "unclaimed" seat, shown alongside the claimed
    # (membership) rows rather than as a separate concept to track.
    @pending_invites = @funder.invites.licensee.pending.order(:created_at)

    org_ids = @memberships.map(&:organisation_id)
    surveys = Survey.where(organisation_id: org_ids).kept
    @published_counts_by_org = surveys.where.not(publish_token: nil).group(:organisation_id).count
    @completed_response_counts_by_org = Response.joins(:survey)
      .where(status: "completed", surveys: { organisation_id: org_ids })
      .group("surveys.organisation_id").count

    @portfolios = @funder.portfolios.kept
                    .includes(portfolio_memberships: { funder_membership: :organisation })
                    .order(:name)
    # An org grouped under a Portfolio is shown there instead — the flat list
    # below only holds orgs not yet assigned to any Portfolio.
    grouped_membership_ids = PortfolioMembership.where(portfolio_id: @portfolios.map(&:id)).pluck(:funder_membership_id)
    @unassigned_memberships = @memberships.reject { |m| grouped_membership_ids.include?(m.id) }
    @new_portfolio = @funder.portfolios.new
  end

  def load_member_show_data
    @other_members = @funder.member_organisations
                       .where(funder_memberships: { status: "active" })
                       .where.not(id: current_organisation.id)
                       .distinct
    @total_partner_count = @funder.funder_memberships.active.count
  end
end
