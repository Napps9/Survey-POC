# The tail of an import: fill in every secondary language, then populate imagery.
#
# BuildVertoJob already runs these for a wizard-generated Verto, but an import
# stops at the reviewed payload and hands back to a request thread — which then
# ran both of these inline. On a PDF import of 30 questions across five languages
# that's five Claude calls plus a run of Pexels lookups, all on one of this
# instance's three Puma threads.
#
# Unlike the wizard, an import's creator is NOT held on a wait screen: they land
# in the editor while this is still running. So the deck can be edited and saved
# from under this job, and writing the pre-translation cards back would silently
# undo that save. Hence the digest guard — if the deck moved, the translations are
# dropped rather than the creator's edit. Losing a translation is recoverable (the
# per-card Optimise and a re-save regenerate it); losing an edit is not.
#
# Asset population is safe either way: AssetPopulator only fills in cards that
# have no image yet, so a creator who picked their own imagery keeps it.
class FinishVertoSetupJob < ApplicationJob
  queue_as :default

  # No retries: translation and asset population each rescue internally, so
  # reaching here means something structural, and a retry would re-bill the
  # translation calls.
  discard_on StandardError do |job, error|
    ErrorReporting.report("FinishVertoSetupJob", error, survey_id: job.arguments.first)
  end

  def perform(survey_id, cards_digest = nil)
    survey = Survey.find_by(id: survey_id)
    return unless survey

    VertoGeneration.translate_survey!(survey, if_unchanged: cards_digest)
    VertoGeneration.auto_populate_assets!(survey.reload)
  end
end
