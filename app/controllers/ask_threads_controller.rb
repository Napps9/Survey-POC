# Ask Verto conversations: starting one, and reopening one.
#
# Threads belong to the organisation rather than the person who typed the
# question — an answer a colleague already got is worth finding again, and the
# corpus behind it is identical either way.
class AskThreadsController < ApplicationController
  def create
    thread = Current.organisation.ask_threads.create!(
      user:  Current.user,
      title: params[:title].presence&.truncate(120),
      scope: scope_params
    )
    AskThread.prune!(Current.organisation)

    redirect_to ask_path(thread_id: thread.id)
  end

  def destroy
    Current.organisation.ask_threads.find(params[:id]).destroy
    redirect_to ask_path, notice: t("ask.thread.deleted")
  end

  private

  # Only the filters the corpus actually understands. Anything else would be
  # stored, shown back as if it applied, and silently ignored by the tools.
  def scope_params
    params.fetch(:scope, {}).permit(:theme, :country).to_h.compact_blank
  end
end
