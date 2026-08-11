# The "Submit your Verto data" picker on the ask screen (agreed 2026-08-11):
# a batch of opt-ins with question-set granularity, in one submission.
#
# Everything the picker claims is re-derived here. The survey must belong to
# the current organisation, must be in the `:ready` submittable state (the
# picker's locked rows are presentation, this is the guard), and the offered
# set ids are intersected against the sets the survey's cards actually carry —
# a crafted POST can't offer another org's Verto, an unpublished one, or a
# question set the Verto doesn't contain.
#
# One submission → one team notification and one submitter confirmation,
# however many Vertos it carried. Decisions are emailed per entry from the
# review queue (CorpusReviewsController).
class AskSubmissionsController < ApplicationController
  include RequiresAskVertoAccess

  before_action :require_admin!

  def create
    entries = submissions.filter_map { |survey_id, selection| offer!(survey_id, selection) }

    if entries.any?
      AskSubmissionMailer.team_notification(Current.user, entries).deliver_later
      AskSubmissionMailer.submitter_confirmation(Current.user, entries).deliver_later
    end

    # `submitted` re-opens the picker in its success state — the modal the
    # form posted from shows the confirmation, exactly as the mock has it.
    redirect_to ask_path(submitted: entries.size)
  end

  private

  def offer!(survey_id, selection)
    survey = Current.organisation.surveys.kept.find_by(id: survey_id)
    return nil unless survey

    answered = CorpusIndexer.countable_responses(survey).count
    return nil unless CorpusEntry.submittable_state(survey, answered_count: answered) == :ready

    scope = scope_for(survey, selection)
    return nil if scope == :nothing

    entry = CorpusEntry.for(survey)
    entry.save! unless entry.persisted?
    entry.opt_in!(Current.user, scope: scope)
    entry
  end

  # The stored scope, from what the form ticked. Whole-Verto selections store
  # `{}` — the same meaning every pre-picker entry already has — so "all of
  # it" stays one representation however it was arrived at.
  def scope_for(survey, selection)
    survey_set_ids = Array(survey.cards).filter_map { |c| c["common_question_set_id"] }.map(&:to_i).uniq
    own     = ActiveModel::Type::Boolean.new.cast(selection["own"]) == true
    set_ids = Array(selection["set_ids"]).map(&:to_i).uniq & survey_set_ids

    return :nothing if !own && set_ids.empty?
    return {} if own && (survey_set_ids - set_ids).empty?

    { "own_questions" => own, "common_question_set_ids" => set_ids }
  end

  # vertos[<survey_id>][own] / vertos[<survey_id>][set_ids][]. Values are
  # re-validated above (booleans cast, ids intersected against the survey's
  # own cards), so the raw read carries no authority.
  def submissions
    raw = params[:vertos]
    return {} unless raw.is_a?(ActionController::Parameters)

    raw.to_unsafe_h.to_h do |survey_id, selection|
      selection = selection.is_a?(Hash) ? selection : {}
      [ survey_id.to_i, { "own" => selection["own"], "set_ids" => Array(selection["set_ids"]) } ]
    end
  end
end
