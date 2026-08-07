# The Ask Verto product page.
#
# Open to any signed-in account. That is a product decision, not an oversight:
# what a person can see is decided entirely by the corpus, and the corpus is the
# same for everyone — CorpusTools reads CorpusEntry.citable and has no parameter
# that could widen it. So "who is asking" never changes what can be answered, and
# there is exactly one authorisation rule in the feature rather than two that can
# disagree.
#
# Note what this means for an org's OWN data: a Verto they have not offered (or
# that we have not approved) is invisible here even to the people who collected
# it. They have /surveys/:id/results and the per-Verto chat for that. Ask Verto
# answers from the shared corpus or it answers from nothing.
class AskController < ApplicationController
  # An app shell, like the editor and the results screen: the conversation and
  # the folder scroll inside their own columns, and the page itself never does.
  # Keeps the bottom nav — unlike the editor, this is a destination you arrive
  # at rather than a workspace you leave.
  layout "fullscreen"

  def show
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
