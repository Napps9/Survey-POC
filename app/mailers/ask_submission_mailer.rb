# The three emails of the Ask Verto submission loop (agreed 2026-08-11):
# the Verto team learns a submission arrived, the submitter learns it was
# received, and the submitter learns the decision.
#
# The team notification is staff-facing and English-only, like the review
# queue it links to. The two submitter emails are localised the way
# WelcomeMailer is — a mailer runs in a job with no request and therefore no
# Current.locale, so the recipient's own preferred_locale is applied
# explicitly.
class AskSubmissionMailer < ApplicationMailer
  # Where submission notifications land. Comma-separated, overridable at the
  # environment level; the default is the two addresses the owner named.
  TEAM_EMAILS = ENV.fetch("ASK_REVIEW_EMAILS", "nick@playverto.com,Tech@playverto.com")

  def self.team_recipients
    TEAM_EMAILS.split(/[,\s]+/).map(&:strip).reject(&:blank?)
  end

  # "Nick Apps (WLL Global) has offered these Vertos." One email per
  # submission — a batch from the picker is one submission — listing every
  # entry with what was offered, linking to the review queue.
  def team_notification(user, entries)
    @user    = user
    @entries = entries
    @rows    = offer_rows(entries)
    @organisation = entries.first.organisation

    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(
      to:       self.class.team_recipients,
      subject:  "Ask Verto — #{entries.size} #{"Verto".pluralize(entries.size)} submitted for review",
      reply_to: user.email_address
    )
  end

  # "We received it" — sent to whoever submitted, in their own language.
  def submitter_confirmation(user, entries)
    @user    = user
    @entries = entries
    @rows    = offer_rows(entries)

    I18n.with_locale(SupportedLocales.coerce(user.preferred_locale)) do
      headers["X-Entity-Ref-ID"] = SecureRandom.uuid
      mail(
        to:       user.email_address,
        subject:  t("ask_submission_mailer.confirmation_subject"),
        reply_to: ENV["MAIL_REPLY_TO"].presence
      )
    end
  end

  # The decision, approved or declined, to the person who offered the Verto.
  # A decline carries the reviewer's note verbatim — it was written to be
  # shown to the creator (see CorpusEntry#decline!).
  def decision(entry)
    @entry = entry
    @user  = entry.opted_in_by
    return unless @user

    @verto = entry.survey.title.presence || entry.survey.theme

    I18n.with_locale(SupportedLocales.coerce(@user.preferred_locale)) do
      headers["X-Entity-Ref-ID"] = SecureRandom.uuid
      key = entry.approved? ? "approved_subject" : "declined_subject"
      mail(
        to:       @user.email_address,
        subject:  t("ask_submission_mailer.#{key}", verto: @verto),
        reply_to: ENV["MAIL_REPLY_TO"].presence
      )
    end
  end

  private

  # What each email lists per Verto: how many people answered, and whether the
  # whole deck or a narrowed question-set selection was offered. Computed once
  # here so the HTML and text parts can't disagree.
  def offer_rows(entries)
    entries.map do |entry|
      cards = Array(entry.survey.cards).select { |c| CorpusIndexer.indexable?(c["type"].to_s) }
      {
        name:      entry.survey.title.presence || entry.survey.theme,
        responses: CorpusIndexer.countable_responses(entry.survey).count,
        total:     cards.size,
        offered:   cards.count { |c| entry.offers_card?(c) },
        whole:     entry.whole_verto_offered?
      }
    end
  end
end
