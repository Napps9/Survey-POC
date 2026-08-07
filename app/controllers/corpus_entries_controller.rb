# The creator's half of the Ask Verto consent gate.
#
# Its own controller rather than a field on SurveysController#update_settings,
# for two reasons. Consent needs an audit trail — who offered it and when — which
# a settings hash doesn't carry. And offering another organisation's researchers
# access to your respondents' answers is an admin decision, not an editing one;
# every other toggle in that panel changes how a Verto behaves, this one changes
# who can see what it collected.
class CorpusEntriesController < ApplicationController
  before_action :require_admin!
  before_action :set_survey

  def create
    entry = CorpusEntry.for(@survey)
    entry.save! unless entry.persisted?
    entry.opt_in!(Current.user)

    redirect_back fallback_location: survey_path(@survey),
                  notice: t("ask.opt_in.offered")
  end

  def destroy
    entry = CorpusEntry.find_by(survey_id: @survey.id)
    # Withdrawing something never offered is a no-op, not an error — a
    # double-submitted form should not show the creator a failure.
    entry&.withdraw!

    redirect_back fallback_location: survey_path(@survey),
                  notice: t("ask.opt_in.withdrawn")
  end

  private

  # Scoped to the current organisation, so a creator can only offer their own
  # Verto. The one cross-organisation read in this feature is CorpusTools, and
  # it is not reachable from here.
  def set_survey
    @survey = Current.organisation.surveys.find(params[:survey_id])
  end
end
