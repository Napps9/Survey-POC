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
  end
end
