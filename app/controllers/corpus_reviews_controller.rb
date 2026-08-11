# VertoNow's half of the consent gate: the queue of Vertos whose creators have
# offered them and which are waiting on us.
#
# Access is a ROUTING CONSTRAINT, not a before_action — see config/routes.rb.
# A non-staff request doesn't get a 403, it gets a 404, because the existence of
# an internal review surface over other customers' data is itself something
# customers have no reason to learn. That is the same call already made for
# /blazer, and it reuses the same allowlist so there is one list to keep correct.
class CorpusReviewsController < ApplicationController
  TABS = %w[pending approved declined withdrawn].freeze

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "pending"

    @counts = {
      "pending"   => CorpusEntry.awaiting_review.count,
      "approved"  => CorpusEntry.citable.count,
      "declined"  => CorpusEntry.offered.where(review_status: "declined").count,
      "withdrawn" => CorpusEntry.withdrawn.count
    }

    @entries = entries_for(@tab).includes(:survey, :organisation, :opted_in_by).limit(100)
    # Checks are computed for display only. Nothing here decides anything — the
    # reviewer does, on a pre-flagged row rather than from scratch.
    @checks = @entries.to_h { |entry| [ entry.id, CorpusChecks.run(entry.survey, answered_count: answered_count(entry)) ] }

    # One entry's on-demand answer preview — aggregated in memory for exactly
    # the row the reviewer expanded, never for the whole queue, because the
    # aggregation walks every response of the Verto.
    @preview_entry = @entries.find { |entry| entry.id == params[:preview].to_i } if params[:preview].present?
    @preview_rows  = @preview_entry ? CorpusIndexer.new(@preview_entry).preview_rows : []
  end

  def update
    entry = CorpusEntry.find(params[:id])

    case params[:decision]
    when "approve"
      entry.approve!(reviewer_email)
      # Indexing happens in a job: aggregating every response of a large Verto is
      # exactly the memory shape that restarts this process (see the job).
      IndexCorpusEntryJob.perform_later(entry.id)
      AskSubmissionMailer.decision(entry).deliver_later
      notice = t("ask.review.approved", verto: verto_name(entry))
    when "decline"
      entry.decline!(reviewer_email, params[:review_note])
      # A declined Verto's rows go now rather than at the next refresh — we have
      # said no, so holding an index of it is holding data we decided not to use.
      entry.corpus_questions.destroy_all
      # The creator reads the note verbatim, in their own language, from
      # their inbox — not only if they happen to revisit the survey page.
      AskSubmissionMailer.decision(entry).deliver_later
      notice = t("ask.review.declined", verto: verto_name(entry))
    else
      return redirect_to corpus_reviews_path, alert: t("ask.review.unknown_decision")
    end

    redirect_to corpus_reviews_path(tab: params[:tab]), notice: notice
  end

  private

  def entries_for(tab)
    case tab
    when "approved"  then CorpusEntry.citable.order(reviewed_at: :desc)
    when "declined"  then CorpusEntry.offered.where(review_status: "declined").order(reviewed_at: :desc)
    when "withdrawn" then CorpusEntry.withdrawn.order(withdrawn_at: :desc)
    else CorpusEntry.awaiting_review
    end
  end

  # The population the indexer will actually count — everyone who answered
  # something — so the queue's check agrees with what enrolment would do.
  def answered_count(entry)
    CorpusIndexer.countable_responses(entry.survey).count
  end

  def verto_name(entry)
    entry.survey.title.presence || entry.survey.theme.presence || "Verto ##{entry.survey_id}"
  end

  # The routing constraint already proved this request is staff; this is only
  # for the audit trail.
  def reviewer_email
    Current.user&.email_address.to_s
  end
end
