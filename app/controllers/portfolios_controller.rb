class PortfoliosController < ApplicationController
  layout "fullscreen"

  before_action :load_funder
  before_action :load_portfolio, only: [ :show, :destroy, :results, :resync ]
  before_action :require_funder_owner!, only: [ :new, :create, :destroy, :results, :resync ]

  # Owner sees every portfolio under this funder; a grantee only sees the
  # portfolio(s) their own org actively belongs to — never the funder's full
  # roster of other grantees.
  def index
    @owner = owner?
    @portfolios = if @owner
      @funder.portfolios.kept.order(:name)
    else
      @funder.portfolios.kept
             .joins(portfolio_memberships: :funder_membership)
             .where(funder_memberships: { organisation_id: current_organisation.id, status: "active" })
             .order(:name)
    end
  end

  def new
    @portfolio = @funder.portfolios.new
  end

  def create
    @portfolio = @funder.portfolios.new(portfolio_params)
    if @portfolio.save
      redirect_to funder_portfolio_path(@funder, @portfolio), notice: "Portfolio \"#{@portfolio.name}\" created."
    else
      flash.now[:alert] = @portfolio.errors.full_messages.first
      render :new, status: :unprocessable_entity
    end
  end

  def show
    if owner?
      load_creator_show_data
      render :creator_show
    else
      load_member_show_data
      render :member_show
    end
  end

  def destroy
    @portfolio.archive!
    redirect_to funder_path(@funder), notice: "Portfolio \"#{@portfolio.name}\" removed."
  end

  # GET /funders/:funder_id/portfolios/:id/results — JSON-only, funder-scoped
  # aggregate. No view: the results/dashboard visual language is a separate
  # piece of work, out of scope for this data-layer build.
  def results
    org_ids = @portfolio.active_memberships.pluck("funder_memberships.organisation_id")
    sets = @portfolio.portfolio_common_question_sets
                      .includes(common_question_set: :common_questions)
                      .reject { |pcqs| pcqs.common_question_set.deleted? }

    payload = sets.map do |pcqs|
      set = pcqs.common_question_set
      surveys = set.surveys_using(Survey.where(organisation_id: org_ids).kept)
      per_question, _variants, total_surveys, total_responses =
        CommonQuestionAggregator.new(set, surveys).aggregate

      {
        common_question_set_id: set.id,
        name: set.name,
        total_surveys: total_surveys,
        total_responses: total_responses,
        questions: per_question.map { |row|
          {
            common_question_id: row[:common_question].id,
            text: row[:common_question].text,
            type: row[:type],
            total: row[:total],
            counts: row[:counts],
            texts: row[:texts],
            avg: row[:avg],
            drift: row[:drift?]
          }.compact
        }
      }
    end

    render json: { portfolio: { id: @portfolio.id, name: @portfolio.name },
                   member_organisation_count: org_ids.size, sets: payload }
  end

  # Manual re-splice escape hatch — e.g. after adding a question to a set
  # already attached to this portfolio, which has no automatic sync hook.
  def resync
    PortfolioCommonQuestionSync.ensure_cards_for_portfolio(@portfolio)
    redirect_to funder_portfolio_path(@funder, @portfolio), notice: "Portfolio questions re-synced to every member."
  end

  private

  def load_funder
    @funder = Funder.find_by(id: params[:funder_id])
    unless @funder && (
      @funder.organisation_id == current_organisation.id ||
      @funder.funder_memberships.exists?(organisation_id: current_organisation.id)
    )
      redirect_to funders_path, alert: "Funder not found." and return
    end
  end

  def load_portfolio
    @portfolio = @funder.portfolios.kept.find_by(id: params[:id])
    redirect_to funder_path(@funder), alert: "Portfolio not found." and return unless @portfolio
  end

  def owner?
    @funder.organisation_id == current_organisation.id
  end

  def require_funder_owner!
    return if owner? && current_membership&.admin?
    redirect_to funder_path(@funder), alert: "Only the funder can do that."
  end

  def portfolio_params
    params.require(:portfolio).permit(:name)
  end

  def load_creator_show_data
    @memberships = @portfolio.portfolio_memberships.includes(funder_membership: :organisation).order(:created_at)
    @attached_sets = @portfolio.portfolio_common_question_sets
                        .includes(common_question_set: :common_questions).order(:created_at)
                        .reject { |pcqs| pcqs.common_question_set.deleted? }
    @available_memberships = @funder.funder_memberships.active
                        .where.not(id: @portfolio.portfolio_memberships.select(:funder_membership_id))
                        .includes(:organisation)
    @available_sets = current_organisation.common_question_sets.kept
                        .where.not(id: @attached_sets.map(&:common_question_set_id))
                        .order(:name)
  end

  # A grantee only ever sees their own mandatory question texts for this
  # portfolio — never the roster of fellow grantees, and never the results
  # aggregate (that's the funder-owner-only path above).
  def load_member_show_data
    @questions = CommonQuestion.joins(:common_question_set)
                   .merge(CommonQuestionSet.kept)
                   .where(common_question_set_id: @portfolio.common_question_sets.select(:id))
                   .order(:common_question_set_id, :position)
  end
end
