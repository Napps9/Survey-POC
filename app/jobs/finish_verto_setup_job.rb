# The tail of an import: populate imagery, then fill in every secondary language.
#
# BuildVertoJob already runs these for a wizard-generated Verto, but an import
# stops at the reviewed payload and hands back to a request thread — which then
# ran both of these inline. On a PDF import of 30 questions across five languages
# that's five Claude calls plus a run of Pexels lookups, all on one of this
# instance's three Puma threads.
#
# Unlike the wizard, an import's creator is NOT held on a wait screen: they land
# in the editor while this is still running. So the deck can be edited and saved
# from under this job, and both steps have to survive that — in opposite
# directions, which is why they are guarded differently.
#
# Translation writes the WHOLE deck (every card's i18n map), so it can only be
# all-or-nothing: the digest guard drops the translations when the deck moved,
# because losing a translation is recoverable (the per-card Optimise and a
# re-save regenerate it) and losing an edit is not.
#
# Imagery is per-card, so it merges instead of dropping — AssetPopulator's
# populate_merged! applies each pick to the live card with the same cid, and
# only where that card still has no media. Nothing is lost in either direction.
#
# ── Why imagery goes FIRST ──────────────────────────────────────────────────
# Two reasons, both learned from the same bug report ("images didn't generate
# when they created a Verto with PDF questions").
#
# 1. It is what the creator is looking at. Imagery is seconds of Pexels lookups;
#    translation is one Claude call PER SECONDARY LOCALE, so on a five-language
#    import it is minutes. Running translation first meant the editor sat
#    imageless for that whole time with nothing on screen to say why.
# 2. A translation failure used to cost the imagery entirely. The rescue in
#    VertoGeneration.translate_survey! is inside the per-locale loop; the
#    survey.update! after it is not. A raise there propagated out of #perform,
#    hit `discard_on StandardError`, and the asset population that had not run
#    yet never ran. Each step now has its own rescue as well, so neither can
#    take out the other regardless of order.
class FinishVertoSetupJob < ApplicationJob
  queue_as :default

  # No retries: translation and asset population each rescue internally, so
  # reaching here means something structural, and a retry would re-bill the
  # translation calls.
  discard_on StandardError do |job, error|
    ErrorReporting.report("FinishVertoSetupJob", error, survey_id: job.arguments.first)
  end

  # The digest positional is kept, unused, so jobs already enqueued in Solid
  # Queue at deploy time still deserialise. It described the deck at ENQUEUE
  # time, which is the wrong moment now: this job legitimately changes the deck
  # itself (imagery), so the guard for the translation step has to be taken
  # after that, below.
  def perform(survey_id, _enqueued_cards_digest = nil)
    survey = Survey.find_by(id: survey_id)
    return unless survey

    begin
      VertoGeneration.auto_populate_assets!(survey, fill_only: true, merge: true)
    rescue => e
      ErrorReporting.report("FinishVertoSetupJob imagery", e, survey_id: survey_id)
    end

    begin
      survey.reload
      VertoGeneration.translate_survey!(survey, if_unchanged: VertoGeneration.cards_digest(survey))
    rescue => e
      ErrorReporting.report("FinishVertoSetupJob translate", e, survey_id: survey_id)
    end
  ensure
    # On EVERY exit, including discard_on. The flag is what keeps the editor
    # polling and what keeps SurveysController#update carrying imagery the
    # client can't see yet; a job that dies without clearing it would strand
    # both until SETUP_STALE_AFTER expires.
    survey&.update_columns(setup_pending_since: nil)
  end
end
