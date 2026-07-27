# One PDF build of a results report, produced by a background job and collected
# by the browser when it's ready.
#
# The render is the expensive part: wkhtmltopdf spawns a native process using
# 100-200MB transiently, which on a 512MB instance is enough that two at once
# OOM it — hence the process-wide mutex it used to run behind. That mutex capped
# memory but made a second download wait on a Puma thread, so the fix for one
# problem fed the other. Off the request thread entirely, neither applies.
class ReportRender < ApplicationRecord
  belongs_to :survey
  belongs_to :user

  # The finished file. Attached rather than held in a column: it's a binary
  # document of unbounded size and has no business in the database.
  has_one_attached :document

  STATUSES = %w[pending running succeeded failed].freeze
  validates :status, inclusion: { in: STATUSES }

  def succeeded? = status == "succeeded"
  def failed?    = status == "failed"
  def finished?  = succeeded? || failed?

  def start!   = update!(status: "running")
  def succeed! = update!(status: "succeeded")

  def fail!(message)
    update!(status: "failed", error_message: message.to_s.presence || "Something went wrong.")
  end

  # Same reasoning as VertoBuild: this instance restarts its worker at 85% RSS,
  # and a PDF render is exactly the kind of memory spike that triggers it. A
  # render whose job died must surface as a failure rather than polling forever.
  STALE_AFTER = 5.minutes

  def stale?
    !finished? && updated_at < STALE_AFTER.ago
  end

  # Finished renders are disposable — the report they came from is cached on the
  # survey and can always be re-rendered. Keeping the files would grow the disk
  # for no benefit.
  KEEP_FOR = 1.day

  scope :sweepable, -> { where(created_at: ...KEEP_FOR.ago) }
end
