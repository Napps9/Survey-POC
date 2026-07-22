class PortfolioCommonQuestionSetsController < ApplicationController
  before_action :load_funder
  before_action :load_portfolio
  before_action :require_funder_owner!

  def create
    set = current_organisation.common_question_sets.kept.find(params[:common_question_set_id])
    @portfolio.portfolio_common_question_sets.find_or_create_by!(common_question_set_id: set.id)
    PortfolioCommonQuestionSync.ensure_cards_for_portfolio(@portfolio)
    redirect_to funder_portfolio_path(@funder, @portfolio), notice: "Attached \"#{set.name}\" to #{@portfolio.name}."
  end

  def destroy
    pcqs = @portfolio.portfolio_common_question_sets.find(params[:id])
    pcqs.destroy!
    redirect_to funder_portfolio_path(@funder, @portfolio), notice: "Question set removed from #{@portfolio.name}."
  end

  private

  def load_funder
    @funder = Funder.find_by(id: params[:funder_id])
    redirect_to funders_path, alert: "Funder not found." and return unless @funder
  end

  def load_portfolio
    @portfolio = @funder.portfolios.kept.find_by(id: params[:portfolio_id])
    redirect_to funder_path(@funder), alert: "Portfolio not found." and return unless @portfolio
  end

  def require_funder_owner!
    return if @funder.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to funder_path(@funder), alert: "Only the funder can do that."
  end
end
