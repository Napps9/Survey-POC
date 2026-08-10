# Ask Verto conversations: starting one, and reopening one.
#
# Threads belong to the organisation rather than the person who typed the
# question — an answer a colleague already got is worth finding again, and the
# corpus behind it is identical either way.
class AskThreadsController < ApplicationController
  include RequiresAskVertoAccess

  def create
    thread = Current.organisation.ask_threads.create!(
      user:  Current.user,
      title: params[:title].presence&.truncate(120),
      scope: scope_params
    )
    AskThread.prune!(Current.organisation)

    # A question composed before any thread existed rides through the redirect
    # and is asked by the client on arrival — otherwise the first thing a fresh
    # account types is discarded by the reload that creates its thread.
    redirect_to ask_path(thread_id: thread.id, q: params[:q].presence&.truncate(2000))
  end

  def destroy
    Current.organisation.ask_threads.find(params[:id]).destroy
    redirect_to ask_path, notice: t("ask.thread.deleted")
  end

  private

  # Only the filters the corpus actually applies — today that is :country
  # alone (CorpusTools#scoped_entries). :theme used to be permitted here,
  # which stored it, rendered it as a scope pill, and never narrowed anything:
  # exactly the failure being stored-and-ignored this method exists to
  # prevent. Guarded against scalar params (?scope=foo) because String has no
  # #permit and a malformed query string should not be a 500.
  def scope_params
    scope = params[:scope]
    return {} unless scope.is_a?(ActionController::Parameters)

    scope.permit(:country).to_h.compact_blank
  end
end
