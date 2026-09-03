# Starting and renaming waves — the explicit open/close records behind
# "repeat participation". See Survey#start_next_wave! for why these are real
# rows rather than a derived time window.
#
# There is deliberately no standalone "close" action: the only way a wave
# closes is start_next_wave! opening the one after it, in the same
# transaction. Closing wave N with no wave N+1 would leave new responses
# with survey_wave_id nil — the exact value that means "collected before
# waves began" (wave 1's backfill) — silently misattributing them.
#
# Not admin-gated: unlike SurveyLinksController/ResultsSharesController
# (deciding who gets EXTERNAL visibility into results — an account-level
# call), starting a wave grants no new visibility to anyone outside the
# org. It only reorganises how existing responses are segmented going
# forward, the same "any editor can touch it" bar as update_settings — which
# is also why a viewer is refused: it changes the Verto, and a viewer's role
# is to share and read it.
class SurveyWavesController < ApplicationController
  gate_verto_editing only: %i[ create update ]
  before_action :set_survey

  # POST /surveys/:survey_id/waves — start the next wave, materialising the
  # implicit wave 1 (backfilling every pre-existing response into it) on the
  # very first call. Refused for a Verto that has never been published: there
  # is nothing yet to call "wave 1", and published_at (wave 1's opened_at
  # fallback) would otherwise silently read as created_at.
  def create
    if @survey.published_at.blank?
      return redirect_to survey_path(@survey, panel: "publish"),
                         alert: "Publish this Verto before starting waves — there's nothing to call Wave 1 yet."
    end
    @survey.start_next_wave!(label: params[:label])
    redirect_to survey_path(@survey, panel: "publish")
  end

  # PATCH /surveys/:survey_id/waves/:id — rename only (see class comment for
  # why closing isn't offered here).
  def update
    wave = @survey.survey_waves.find(params[:id])
    wave.update!(label: params[:label].to_s.strip.first(80).presence) if params.key?(:label)
    redirect_to survey_path(@survey, panel: "publish")
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:survey_id])
  end
end
