# The safety net under the moderation queue. Solid Queue runs inside Puma and
# the memory watchdog restarts Puma, so a screen can be lost between enqueue
# and run, or die mid-batch with its rows claimed. Every step is idempotent
# and cheap; it runs every ten minutes in production (config/recurring.yml).
class SweepHeldTextsJob < ApplicationJob
  queue_as :default

  # How long a text may sit pending before we assume its screen was lost.
  # The normal path screens within Moderation::Hold::SCREEN_DEBOUNCE.
  PENDING_STALE_AFTER = 2.minutes
  # Responses re-enqueued per run — enough to drain a backlog in a few runs
  # without one sweep enqueuing a day's worth of jobs at once.
  MAX_REENQUEUE = 200

  discard_on StandardError do |job, error|
    ErrorReporting.report("SweepHeldTextsJob", error)
  end

  def perform
    now = Time.current

    # 1. A batch whose job died mid-screen: back to pending, one attempt spent.
    HeldText.where(status: "screening")
            .where(updated_at: ...(now - Moderation::SCREENING_STALE_AFTER))
            .update_all("status = 'pending', screen_attempts = screen_attempts + 1, updated_at = CURRENT_TIMESTAMP")

    # 2. Pending texts nobody is coming for: re-enqueue their response's screen.
    #    A duplicate is harmless — the job claims rows before it works them.
    HeldText.screenable
            .where(updated_at: ...(now - PENDING_STALE_AFTER))
            .distinct.limit(MAX_REENQUEUE).pluck(:response_id)
            .each { |response_id| ScreenHeldTextsJob.perform_later(response_id) }

    # 3. Removed and superseded texts past their retention: blank the text,
    #    keep the row as the record that a decision was made.
    HeldText.where(status: %w[removed superseded])
            .where(purge_after: ..now)
            .where.not(text: nil)
            .update_all(text: nil, purge_after: nil)
  end
end
