# The hourly booking sweep (config/recurring.yml): for every enabled
# automation, resolve its trigger's subjects, filter conditions and
# suppressions, and insert one run per (subject, anchor) — the UNIQUE
# idempotency_key absorbs every re-run, so this job is safe to fire twice,
# hourly forever, or manually after a restart. Ends by poking the send
# worker if anything is due.
class Comms::EnqueueAutomationRunsJob < ApplicationJob
  queue_as :default

  def perform
    EmailAutomation.where(enabled: true).find_each do |automation|
      subjects = Comms::AutomationTriggers.subjects_for(automation)
      subjects = filter_conditions(automation, subjects)
      next if subjects.empty?

      suppressed = EmailSuppression.where(email: subjects.map { |s| s[:user].email_address })
                                   .pluck(:email).to_set
      now = Time.current
      rows = subjects.filter_map do |s|
        next if suppressed.include?(s[:user].email_address)

        key = [ "a:#{automation.id}", "u:#{s[:user].id}", s[:anchor].utc.iso8601 ]
        key << "org:#{s[:org_id]}" if s[:org_id]
        { email_automation_id: automation.id, user_id: s[:user].id,
          email: s[:user].email_address, name: s[:user].name,
          token: SecureRandom.base58(24), status: "queued",
          idempotency_key: key.join(":"),
          scheduled_at: Comms::SendSlot.resolve(s[:anchor] + automation.delay_minutes.minutes,
                                                automation.send_hour, automation.send_days),
          created_at: now, updated_at: now }
      end
      EmailAutomationRun.insert_all(rows, unique_by: :idempotency_key) if rows.any?
    end

    if EmailAutomationRun.where(status: "queued").where(scheduled_at: ..Time.current).exists?
      Comms::SendAutomationRunsJob.perform_later
    end
  end

  private

  # conditions: {"organisation_ids": [..]} — user-anchored triggers require
  # membership of a listed org; org-anchored triggers require the org itself
  # to be listed. Empty conditions = fire for everyone.
  def filter_conditions(automation, subjects)
    ids = Array(automation.conditions.is_a?(Hash) ? automation.conditions["organisation_ids"] : nil)
          .filter_map { |v| Integer(v, exception: false) }
    return subjects if ids.empty?

    member_ids = Membership.where(organisation_id: ids).pluck(:user_id).to_set
    subjects.select do |s|
      s[:org_id] ? ids.include?(s[:org_id]) : member_ids.include?(s[:user].id)
    end
  end
end
