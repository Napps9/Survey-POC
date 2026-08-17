# Owner-side mutations for the one results_share_token a Verto can have —
# enable (mint), pause/resume, reset (re-mint, killing the old URL), revoke
# (destroy). Mirrors SurveysController#enable_test_link/#disable_test_link
# and SurveyLinksController's active-toggle, but for the /results/:token
# namespace rather than /play or /test. Admin-only for the same reason
# SurveyLinksController is: deciding who gets to see aggregated results is an
# account-level call, not a per-editor one.
class ResultsSharesController < ApplicationController
  before_action :require_admin!
  before_action :set_survey

  # POST /surveys/:id/results_share — mint a token, or re-mint one that's
  # already there (the panel's "Reset link" posts here too, via reset: 1;
  # otherwise an existing token is left alone so re-submitting the enable
  # form can't accidentally rotate a URL already in someone's hands).
  def create
    if @survey.results_share_token.blank? || params[:reset].present?
      @survey.update!(results_share_token: SecureRandom.urlsafe_base64(18), results_share_active: true)
    end
    redirect_to survey_results_path(@survey)
  end

  # PATCH /surveys/:id/results_share — pause or resume. The URL survives a
  # pause (results_share_active: false), unlike revoke below.
  def update
    return redirect_to survey_results_path(@survey) if @survey.results_share_token.blank?

    active = ActiveModel::Type::Boolean.new.cast(params[:active])
    @survey.update!(results_share_active: active) unless active.nil?
    redirect_to survey_results_path(@survey)
  end

  # DELETE /surveys/:id/results_share — hard revoke: the token is gone, so
  # the old URL can never resolve again, distinct from pausing.
  def destroy
    @survey.update!(results_share_token: nil, results_share_active: true)
    redirect_to survey_results_path(@survey)
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:id])
  end
end
