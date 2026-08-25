# One question, answered.
#
# Streams NDJSON rather than the plain text SurveyChatsController writes, because
# an Ask Verto answer is not only prose: sources arrive before the text, quotes
# are printed from records mid-sentence, and citations have to be resolvable as
# they appear. One event per line, so the client can act on each without waiting
# for the next.
#
# ── Spend ─────────────────────────────────────────────────────────────────────
# A turn here is up to MAX_TOOL_ROUNDS + 2 Claude calls (the last only when the
# answer turn came back wordless and is asked again); the per-Verto chat is
# one Haiku call. So the rate limit is a third of that endpoint's, and unlike it
# this one also takes the per-organisation daily cap — a tool loop is the most
# expensive thing a signed-in user can trigger in this app, and the runaway case
# (a stuck client retrying) is the one that shows up on an invoice.
#
# The rounds are cheaper than they read: each one now ends in a tool call rather
# than a discarded answer, and CLAUDE_MODEL_ASK_TOOL_ROUNDS can move them off
# Sonnet entirely. The ceiling below is still sized for the worst case.
class AskMessagesController < ApplicationController
  include ActionController::Live
  include LimitsConcurrentStreams
  include ThrottlesAiSpend
  include RequiresAskVertoAccess

  limit_concurrent_streams only: :create

  # A third of the per-Verto chat's 60/hour, because a turn here costs several
  # Sonnet calls where that one costs a single Haiku call.
  HOURLY_LIMIT = 20

  throttle_ai to: HOURLY_LIMIT, within: 1.hour, name: "ask-verto", respond: :plain, only: %i[ create ]
  cap_ai_spend only: %i[ create ], respond: :plain

  def create
    thread = Current.organisation.ask_threads.find(params[:thread_id])
    # The composer is disabled while the corpus is empty, but the API must not
    # be pokeable into a five-Claude-call way to hear "I have no data" — and
    # refusing BEFORE the question persists means no dangling turn either.
    return head(:unprocessable_entity) if CorpusEntry.citable.none?

    body     = JSON.parse(request.body.read)
    question = body["message"].to_s.strip
    return head(:bad_request) if question.blank?

    thread.ask_messages.create!(role: "user", text: question.truncate(2000))

    response.headers["Content-Type"]      = "application/x-ndjson; charset=utf-8"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Cache-Control"]     = "no-cache"

    result = AskVertoChat.new.call(
      messages: thread.prompt_messages,
      scope:    thread.scope
    ) { |event| write_event(event) }

    persist!(thread, result)
  rescue ActiveRecord::RecordNotFound
    raise # a clean 404 before any stream is opened
  rescue => e
    ErrorReporting.report("AskMessagesController", e)
    begin
      write_event(t: "error", text: t("ask.chat.error"))
    rescue => write_error
      # The client gets a zero-byte 200 in this case — this log line is the
      # only trace that the turn failed twice.
      Rails.logger.warn("[AskVerto] failed to write error event: #{write_error.class}: #{write_error.message}")
    end
  ensure
    response.stream.close if response.committed?
  end

  private

  def write_event(event)
    response.stream.write("#{event.to_json}\n")
  end

  # Citations are stored WITH the message, as a snapshot of what was cited at the
  # time — see AskMessage for why a live join would be wrong.
  def persist!(thread, result)
    return if result.nil? || result[:text].blank?

    thread.ask_messages.create!(role: "assistant", text: result[:text],
                                citations: result[:citations])
    thread.touch
  end
end
