class PartnershipCommonQuestionSetsController < ApplicationController
  layout "fullscreen"

  before_action :load_partnership
  before_action :require_creator_admin!

  def create
    set = current_organisation.common_question_sets.kept.find(params[:common_question_set_id])
    @partnership.partnership_common_question_sets.find_or_create_by!(common_question_set_id: set.id)
    redirect_to partnership_path(@partnership), notice: "Shared \"#{set.name}\" with #{@partnership.name}."
  end

  def destroy
    acs = @partnership.partnership_common_question_sets.find(params[:id])
    acs.destroy!
    redirect_to partnership_path(@partnership), notice: "Question set removed from #{@partnership.name}."
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
    return if @partnership.nil? # load_partnership already redirected
    return if @partnership.organisation_id == current_organisation.id && current_membership&.admin?
    redirect_to partnership_path(@partnership), alert: "Only the partnership creator can do that."
  end
end
