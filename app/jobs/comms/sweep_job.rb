# The safety net under set(wait_until:). Solid Queue runs inside Puma and
# the memory watchdog hot-restarts Puma, so a scheduled job can vanish and
# an in-flight batch can die mid-claim. Every 5 minutes (config/
# recurring.yml) this sweep makes those losses honest:
#
#   (a) due scheduled campaigns whose job was lost → re-enqueued;
#   (b) recipients stuck in `sending` past STALE_AFTER → failed (claimed
#       but never confirmed — at-most-once means we do NOT resend them);
#   (c) sending campaigns untouched past STALE_AFTER with queued rows →
#       batch job re-poked (claims make double-enqueue harmless);
#   (d) sending campaigns with nothing left pending → finalized.
class Comms::SweepJob < ApplicationJob
  queue_as :default

  STALE_AFTER = 10.minutes

  def perform
    EmailCampaign.where(status: "scheduled").where(scheduled_for: ..Time.current).find_each do |campaign|
      Comms::StartCampaignSendJob.perform_later(campaign.id)
    end

    # Automation runs: reap stuck claims (at-most-once — never resend), then
    # re-poke the drain if due work is sitting idle.
    EmailAutomationRun.where(status: "sending").where(updated_at: ..STALE_AFTER.ago)
                      .update_all(status: "failed", error: "lost to a restart mid-send",
                                  updated_at: Time.current)
    if EmailAutomationRun.where(status: "queued").where(scheduled_at: ..STALE_AFTER.ago).exists?
      Comms::SendAutomationRunsJob.perform_later
    end

    EmailCampaign.where(status: "sending").where(updated_at: ..STALE_AFTER.ago).find_each do |campaign|
      campaign.email_campaign_recipients
              .where(status: "sending").where(updated_at: ..STALE_AFTER.ago)
              .update_all(status: "failed", error: "lost to a restart mid-send", updated_at: Time.current)

      pending = campaign.email_campaign_recipients.where(status: %w[queued sending])
      if pending.exists?
        Comms::SendCampaignBatchJob.perform_later(campaign.id)
      else
        Comms::SendCampaignBatchJob.finalize(campaign)
      end
    end
  end
end
