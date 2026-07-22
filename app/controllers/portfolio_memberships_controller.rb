class PortfolioMembershipsController < ApplicationController
  before_action :load_funder
  before_action :load_portfolio
  before_action :require_funder_owner!

  def create
    funder_membership = @funder.funder_memberships.active.find(params[:funder_membership_id])
    PortfolioMembership.join!(portfolio: @portfolio, funder_membership: funder_membership)
    redirect_to funder_portfolio_path(@funder, @portfolio),
                notice: "Added #{funder_membership.organisation.name} to #{@portfolio.name}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to funder_portfolio_path(@funder, @portfolio), alert: e.record.errors.full_messages.first
  end

  def destroy
    membership = @portfolio.portfolio_memberships.find(params[:id])
    membership.destroy!
    redirect_to funder_portfolio_path(@funder, @portfolio), notice: "Removed from #{@portfolio.name}."
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
