# Fills in the i18n entries for languages ADDED to an existing Verto — from the
# editor's Language settings, or from the Language check screen's rail. The
# after-the-fact twin of the translation pass BuildVertoJob runs at creation.
#
# ONE LOCALE PER JOB, and the deck is written as soon as that locale is done.
#
# It used to take every added locale in a single job and write the whole deck
# once at the end. That was survivable while the only way to add a language was
# the editor's checkbox list, one or two at a time. The Language check rail
# invites a creator to tick six at once, which turned a 40-second run into a
# 4-6 minute one — and every failure mode in that window was all-or-nothing:
#
#   * the digest guard compares against a fingerprint taken BEFORE the first
#     call, so any deck change in those minutes (an autosave from an open
#     editor tab, another session, FinishVertoSetupJob) dropped every language
#     in the run, including the five that had already succeeded;
#   * jobs run as threads inside Puma on a 512MB instance with a memory
#     watchdog that re-execs the process at 90% (config/puma.rb, render.yaml),
#     so a restart mid-run lost the lot;
#   * discard_on StandardError meant any error outside the per-locale rescue
#     ended the run with no retry and nothing written.
#
# Splitting by locale makes each unit ~40 seconds and independently durable:
# Turkish failing cannot cost you Spanish, and a restart loses at most the
# language that was in flight. SurveyTranslation records what happened, so the
# screen can say "failed, retry" instead of showing "Translating…" for ever.
class TranslateLocalesJob < ApplicationJob
  queue_as :default

  # Retry rather than discard. A Claude call fails for transient reasons far
  # more often than permanent ones, and the old discard turned a blip into a
  # language that silently never arrived.
  retry_on StandardError, wait: :polynomially_longer,
           attempts: SurveyTranslation::MAX_ATTEMPTS do |job, error|
    survey_id, locales = job.arguments
    ErrorReporting.report("TranslateLocalesJob", error, survey_id: survey_id)
    Array(locales).each do |loc|
      SurveyTranslation.find_by(survey_id: survey_id, locale: loc)
                       &.failed!(error.message, retryable: false)
    end
  end

  # `locales` stays an Array for the callers (and the jobs already enqueued
  # against the old signature) that pass several. Each becomes its own job, so
  # a six-language request is six independent units of work.
  def self.enqueue_for(survey, locales)
    Array(locales).each do |locale|
      SurveyTranslation.enqueue!(survey, locale)
      perform_later(survey.id, [ locale ])
    end
  end

  def perform(survey_id, locales)
    survey = Survey.find_by(id: survey_id)
    return unless survey

    wanted = SupportedLocales.sanitize_list(locales, fallback: []) & survey.secondary_locales
    return if wanted.empty?

    wanted.each { |locale| translate_one(survey, locale) }
  end

  private

  # One language, written the moment it is ready.
  #
  # The digest is taken immediately before the write rather than at the top of
  # the run, so the window in which a concurrent save can cost this language is
  # the length of its own Claude call and nothing more. A deck that did move is
  # still not overwritten — that guarantee is the point of the guard — but now
  # only the language in flight is lost, and its row says so.
  def translate_one(survey, locale)
    row = SurveyTranslation.find_or_initialize_by(survey_id: survey.id, locale: locale)
    row.save! if row.new_record?
    row.running!

    survey.reload
    cards = Array(survey.cards)
    # Per CARD, not per locale. The old all-or-nothing skip meant a run that
    # half-landed could never be repaired: every card had *an* entry, so
    # re-ticking the language skipped it for ever. Asking only for the cards
    # that are actually missing one makes a retry finish the job.
    missing = cards.each_index.reject { |i| cards[i].dig("i18n", locale).present? }
    if missing.empty?
      return row.done!
    end

    subset     = missing.map { |i| cards[i] }
    translated = SurveyTranslator.new.call(cards: subset, target_locale: locale,
                                           source_locale: survey.default_locale)
    merged = Survey.merge_card_translations(subset, locale, translated)

    filled = cards.dup
    missing.each_with_index { |card_index, j| filled[card_index] = merged[j] }

    digest = VertoGeneration.cards_digest(survey)
    if VertoGeneration.write_cards_if_unchanged!(survey, filled, digest)
      row.done!
    else
      # The deck moved under this language. Not an error — the guard did its
      # job — but it is not done either, so it goes back in the queue.
      row.failed!("the deck changed while this language was being translated", retryable: true)
      raise ActiveRecord::StaleObjectError.new(survey, "translate")
    end
  rescue ActiveRecord::StaleObjectError
    raise
  rescue => e
    ErrorReporting.report("TranslateLocalesJob locale", e, locale: locale, survey_id: survey.id)
    row&.failed!(e.message, retryable: true)
    raise
  end
end
