# Minting, pausing and revoking the links that let somebody without an account
# review a Verto's wording.
#
# Admin-only, the same bar as SurveyLinksController and ResultsSharesController:
# handing a stranger a URL that can rewrite live respondent-facing copy is an
# account-level decision, not a per-editor one. Reading the Language check
# screen itself is open to every seat.
class LanguageCheckLinksController < ApplicationController
  before_action :require_admin!
  before_action :set_survey

  MAX_PER_SURVEY = 20

  # POST /surveys/:survey_id/language_check/links
  def create
    if @survey.language_check_links.count >= MAX_PER_SURVEY
      return redirect_back_to_screen(error: "limit")
    end

    @survey.language_check_links.create!(
      name:            params[:name].to_s.strip.first(LanguageCheckLink::MAX_NAME).presence,
      # [] means every language. A creator who tries to scope a link to a
      # language the Verto does not have gets a link to everything rather than
      # a link to nothing, which is the failure they can actually see.
      locales:         SupportedLocales.sanitize_list(params[:locales], fallback: []) & @survey.verto_locales,
      can_edit:        ActiveModel::Type::Boolean.new.cast(params[:can_edit]) != false,
      created_by_user: Current.user
    )
    redirect_back_to_screen
  end

  # PATCH /surveys/:survey_id/language_check/links/:id — pause, resume, or
  # change edit rights on a link already in someone's hands. The URL survives,
  # unlike #destroy.
  def update
    link = @survey.language_check_links.find(params[:id])
    attrs = {}
    active = ActiveModel::Type::Boolean.new.cast(params[:active])
    attrs[:active] = active unless active.nil?
    can_edit = ActiveModel::Type::Boolean.new.cast(params[:can_edit])
    attrs[:can_edit] = can_edit unless can_edit.nil?
    link.update!(attrs) if attrs.any?
    redirect_back_to_screen
  end

  # DELETE /surveys/:survey_id/language_check/links/:id — hard revoke: the
  # token is gone, so the URL can never resolve again.
  #
  # What the link's holder DID is not revoked with it. Their approvals and
  # notes stay (the associations nullify rather than cascade) — deleting the
  # record of who checked the Spanish because the link expired would quietly
  # reset a Verto's review state to "nobody has looked at this".
  def destroy
    @survey.language_check_links.find(params[:id]).destroy!
    redirect_back_to_screen
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:survey_id])
  end

  def redirect_back_to_screen(error: nil)
    redirect_to survey_language_check_path(@survey, link_error: error, anchor: "language-check-links")
  end
end
