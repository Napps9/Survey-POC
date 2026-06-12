class AllianceCommonQuestionSetsController < ApplicationController
  layout "fullscreen"

  before_action :load_alliance
  before_action :require_creator_admin!

  def create
    set = current_organisation.common_question_sets.kept.find(params[:common_question_set_id])
    @alliance.alliance_common_question_sets.find_or_create_by!(common_question_set_id: set.id)
    redirect_to alliance_path(@alliance), notice: "Shared \"#{set.name}\" with #{@alliance.name}."
  end

  def destroy
    acs = @alliance.alliance_common_question_sets.find(params[:id])
    acs.destroy!
    redirect_to alliance_path(@alliance), notice: "Question set removed from #{@alliance.name}."
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
    return if @alliance.nil? # load_alliance already redirected
    return if @alliance.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to alliance_path(@alliance), alert: "Only the alliance creator can do that."
  end
end
