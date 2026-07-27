# One in-flight Verto generation.
#
# The wizard used to POST and wait: SurveyGenerator, then translation, then
# imagery, all on a Puma request thread for 30-120s. With three threads on one
# worker, a few concurrent creations exhausted the pool and the app 502'd for
# everyone — including pages that never touch Claude. Now the request records a
# build, enqueues BuildVertoJob and returns immediately; the wizard's existing
# overlay polls this row and forwards to the editor when the survey exists.
class VertoBuild < ApplicationRecord
  belongs_to :organisation
  belongs_to :user
  belongs_to :survey, optional: true

  STATUSES = %w[pending running succeeded failed].freeze
  validates :status, inclusion: { in: STATUSES }

  # A build the poller should stop waiting on, either way.
  scope :finished, -> { where(status: %w[succeeded failed]) }

  def pending?   = status == "pending"
  def running?   = status == "running"
  def succeeded? = status == "succeeded"
  def failed?    = status == "failed"
  def finished?  = succeeded? || failed?

  def start!
    update!(status: "running")
  end

  def succeed!(survey)
    update!(status: "succeeded", survey: survey)
  end

  # The message is what the creator sees, so it arrives already humanised by the
  # caller — this only stores it.
  def fail!(message)
    update!(status: "failed", error_message: message.to_s.presence || "Something went wrong.")
  end

  # A build whose job died without ever reporting back — the worker was killed
  # mid-run (puma_worker_killer restarts at 85% RSS on this instance), or the
  # process restarted during a deploy. Without this the wizard would poll a
  # "running" row forever, which looks exactly like a hung app.
  STALE_AFTER = 10.minutes

  def stale?
    !finished? && updated_at < STALE_AFTER.ago
  end
end
