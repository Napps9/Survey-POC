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

      # The primary email plus every sendable follow-up step, each with its
      # own delay-from-anchor and window. A step's key appends :step:<id>,
      # the primary's key is UNCHANGED by steps existing — adding a step
      # later books only the new follow-up, never a primary re-send.
      emails = [ { step: nil, delay: automation.delay_minutes,
                   hour: automation.send_hour, days: automation.send_days } ]
      automation.email_automation_steps.ordered.select(&:sendable?).each do |step|
        emails << { step: step, delay: step.delay_minutes, hour: step.send_hour, days: step.send_days }
      end

      rows = subjects.flat_map do |s|
        next [] if suppressed.include?(s[:user].email_address)

        base_key = [ "a:#{automation.id}", "u:#{s[:user].id}", s[:anchor].utc.iso8601 ]
        base_key << "org:#{s[:org_id]}" if s[:org_id]
        emails.map do |e|
          key = base_key.dup
          key << "step:#{e[:step].id}" if e[:step]
          { email_automation_id: automation.id, email_automation_step_id: e[:step]&.id,
            user_id: s[:user].id, email: s[:user].email_address, name: s[:user].name,
            token: SecureRandom.base58(24), status: "queued",
            idempotency_key: key.join(":"),
            scheduled_at: Comms::SendSlot.resolve(s[:anchor] + e[:delay].minutes,
                                                  e[:hour], e[:days]),
            created_at: now, updated_at: now }
        end
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
