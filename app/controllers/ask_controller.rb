# The Ask Verto product page.
#
# Open to any signed-in account unless ASK_VERTO_USER_EMAILS narrows it
# (RequiresAskVertoAccess). Within whoever may ask, what a person can see is
# decided entirely by the corpus, and the corpus is the same for everyone —
# CorpusTools reads CorpusEntry.citable and has no parameter that could widen
# it. So "who is asking" never changes what can be answered, and there is
# exactly one data-authorisation rule in the feature rather than two that can
# disagree.
#
# Note what this means for an org's OWN data: a Verto they have not offered (or
# that we have not approved) is invisible here even to the people who collected
# it. They have /surveys/:id/results and the per-Verto chat for that. Ask Verto
# answers from the shared corpus or it answers from nothing.
class AskController < ApplicationController
  include RequiresAskVertoAccess

  # An app shell, like the editor and the results screen: the conversation and
  # the folder scroll inside their own columns, and the page itself never does.
  layout "fullscreen"

  def show
    # The editor's trade, adopted 2026-08-11: the nav strip goes, and its
    # survivors float — a glass back pill top-left, the language pill pinned
    # top-right. The command palette stays reachable via ⌘K.
    @hide_main_nav = true

    @threads = Current.organisation.ask_threads.recent.limit(20)
    @thread  = if params[:thread_id].present?
                 Current.organisation.ask_threads.find_by(id: params[:thread_id])
    else
                 @threads.first
    end
    @messages = @thread ? @thread.ask_messages.to_a : []

    tools    = CorpusTools.new
    @coverage = tools.coverage
    # Only built for the cold start — the hero is the only thing that renders
    # them, and they cost a pass over the index.
    @suggestions = @messages.empty? ? tools.suggestions : []

    @submittable = submittable_vertos
  end

  private

  # The "Submit your Verto data" picker's material: the org's Vertos with a
  # submittable state each, and the question sets a ready one can be narrowed
  # to. Admins only — offering respondents' data outward is an admin decision
  # (the same rule CorpusEntriesController enforces) — so for everyone else
  # the CTA and modal simply don't render. Bounded to the 30 newest kept
  # Vertos; an org past that bound manages the rest from each survey's page.
  PICKER_LIMIT = 30

  def submittable_vertos
    return [] unless current_membership&.admin?

    Current.organisation.surveys.kept.order(created_at: :desc).limit(PICKER_LIMIT).map do |survey|
      answered = CorpusIndexer.countable_responses(survey).count
      cards    = Array(survey.cards).select { |c| CorpusIndexer.indexable?(c["type"].to_s) }
      groups   = cards.group_by { |c| c["common_question_set_id"] }
      state    = CorpusEntry.submittable_state(survey, answered_count: answered)

      {
        survey:    survey,
        answered:  answered,
        state:     state,
        # A declined row is selectable again — resubmitting restarts review —
        # and carries the reviewer's note so the admin knows what to fix first.
        decline_note: (CorpusEntry.find_by(survey_id: survey.id)&.review_note if state == :declined),
        total:     cards.size,
        own_count: (groups[nil] || []).size,
        sets:      groups.except(nil).map do |set_id, group|
          set = CommonQuestionSet.find_by(id: set_id)
          { id: set_id, name: set&.name.presence || t("ask.submit.common_set"), count: group.size }
        end
      }
    end.sort_by { |row| %i[ready declined].include?(row[:state]) ? 0 : 1 }
  end
end
