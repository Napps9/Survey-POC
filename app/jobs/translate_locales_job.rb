# Fills in the i18n entries for languages ADDED to an existing Verto from the
# editor's Language settings — the after-the-fact twin of the translation pass
# BuildVertoJob runs at creation.
#
# Deliberately NOT VertoGeneration.translate_survey!: that walks every
# secondary language, and re-translating a language the Verto already carries
# would overwrite translations the creator has hand-edited in the translation
# tab. This job touches only the locales it was handed, and within them only
# the cards that don't already carry an entry — so re-adding a language that
# was deselected earlier is instant and lossless.
#
# The creator is in the editor while this runs (same situation as
# FinishVertoSetupJob), so the digest guard drops the translations rather than
# clobber a concurrent edit; the next save's Optimise path or re-toggling the
# language recovers them.
class TranslateLocalesJob < ApplicationJob
  queue_as :default

  discard_on StandardError do |job, error|
    ErrorReporting.report("TranslateLocalesJob", error, survey_id: job.arguments.first)
  end

  def perform(survey_id, locales)
    survey = Survey.find_by(id: survey_id)
    return unless survey

    wanted = SupportedLocales.sanitize_list(locales, fallback: []) & survey.secondary_locales
    return if wanted.empty?

    digest = VertoGeneration.cards_digest(survey)
    cards  = Array(survey.cards)
    source = survey.default_locale

    changed = false
    wanted.each do |loc|
      next if cards.all? { |c| c.dig("i18n", loc).present? }

      translated = SurveyTranslator.new.call(cards: cards, target_locale: loc, source_locale: source)
      merged = Survey.merge_card_translations(cards, loc, translated)
      cards = cards.each_with_index.map do |c, i|
        c.dig("i18n", loc).present? ? c : merged[i]
      end
      changed = true
    rescue => e
      ErrorReporting.report("TranslateLocalesJob locale", e, locale: loc, survey_id: survey.id)
    end

    VertoGeneration.write_cards_if_unchanged!(survey, cards, digest) if changed
  end
end
