# One in-flight "generate a flow" request.
#
# #generate_flow used to run FlowGenerator plus a translation pass inline on a
# Puma request thread — one Claude call for the flow, then one per secondary
# locale. On a five-language Verto that's six sequential calls against a 120s
# timeout, and with three threads on one worker a couple of concurrent
# generations took the whole app down for everyone.
#
# Same shape as VertoBuild and ReportRender: the request records a row, enqueues
# GenerateFlowJob and returns; the editor polls and splices when it's ready.
#
# What's stored is card JSON, not rendered HTML. The slow part is Claude; turning
# cards into editor markup is fast and needs a view context, so it stays in the
# request that polls (FlowGenerationsController#show).
class FlowGeneration < ApplicationRecord
  belongs_to :survey
  belongs_to :user

  STATUSES = %w[pending running succeeded failed].freeze
  validates :status, inclusion: { in: STATUSES }

  def pending?   = status == "pending"
  def running?   = status == "running"
  def succeeded? = status == "succeeded"
  def failed?    = status == "failed"
  def finished?  = succeeded? || failed?

  def start! = update!(status: "running")

  def succeed!(cards:, flow_name:)
    update!(status: "succeeded", cards: cards, flow_name: flow_name)
  end

  # The message is what the creator reads, so it arrives already humanised.
  def fail!(message)
    update!(status: "failed", error_message: message.to_s.presence || "Something went wrong.")
  end

  # A generation whose job died without reporting back — the memory watchdog
  # recycles Puma (and Solid Queue with it) when the container nears its limit,
  # and a deploy does the same. Without this the editor would poll a "running"
  # row forever, which looks exactly like a hung app.
  STALE_AFTER = 6.minutes

  def stale?
    !finished? && updated_at < STALE_AFTER.ago
  end

  # Finished rows are disposable: the cards have been spliced into the editor's
  # DOM and saved with the deck by then.
  scope :collectable, -> { where(status: %w[succeeded failed]).where(updated_at: ..1.day.ago) }
end
