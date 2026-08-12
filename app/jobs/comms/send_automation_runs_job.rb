# Drains due automation runs in the same shape as the campaign batch
# sender: claim-then-send in small throttled batches, self-re-enqueue while
# work remains. Suppression is re-checked at send time — an unsubscribe
# that landed after booking still wins. Automation mail carries the
# unsubscribe link and open pixel but no click wrapping (the links table is
# campaign-scoped; a comment, not an accident).
class Comms::SendAutomationRunsJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 25
  THROTTLE = 0.1

  discard_on StandardError do |_job, error|
    ErrorReporting.report("Comms::SendAutomationRunsJob", error)
  end

  def perform
    batch = EmailAutomationRun.where(status: "queued").where(scheduled_at: ..Time.current)
                              .order(:id).limit(BATCH_SIZE).to_a
    return if batch.empty?

    batch.each do |run|
      claimed = EmailAutomationRun.where(id: run.id, status: "queued")
                                  .update_all(status: "sending", updated_at: Time.current)
      next if claimed.zero?

      deliver(run)
      sleep THROTTLE
    end

    if EmailAutomationRun.where(status: "queued").where(scheduled_at: ..Time.current).exists?
      self.class.perform_later
    end
  end

  private

  def deliver(run)
    automation = run.email_automation
    if automation.nil? || !automation.enabled? || automation.compiled_html.blank?
      run.update_columns(status: "skipped", updated_at: Time.current)
      return
    end
    if EmailSuppression.exists?(email: run.email)
      run.update_columns(status: "suppressed", updated_at: Time.current)
      return
    end

    if Comms::Delivery.live?
      Comms::AutomationMailer.automation_email(run.id).deliver_now
      run.update_columns(status: "sent", sent_at: Time.current, updated_at: Time.current)
      EmailEvent.log!("sent", automation_run: run)
    else
      run.update_columns(status: "simulated", sent_at: Time.current, updated_at: Time.current)
      EmailEvent.log!("simulated", automation_run: run)
    end
  rescue => e
    ErrorReporting.report("Comms::SendAutomationRunsJob#deliver", e)
    run.update_columns(status: "failed", error: e.message.to_s.first(200), updated_at: Time.current)
    EmailEvent.log!("failed", automation_run: run)
  end
end
