# Delivers a sending campaign in small batches sized for this app's Solid
# Queue reality: two worker threads inside the web process. Each invocation
# claims up to BATCH_SIZE queued recipients, personalizes and mails them
# with a throttle, then RE-ENQUEUES ITSELF for the rest — yielding the
# thread between batches so a big send never starves other jobs, and
# keeping each job invocation short enough that a memory-watchdog restart
# loses at most one batch.
#
# Claim-then-send is the at-most-once rule: a recipient is flipped
# queued→sending with a guarded UPDATE before any mail goes out, so a
# restart mid-batch leaves claimed-but-unsent rows in `sending` for the
# sweeper to reap as failed — an honest error, never a double email.
# Cancellation is checked between batches: a cancelled campaign's queued
# rows become skipped and the chain stops.
class Comms::SendCampaignBatchJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 25
  THROTTLE = 0.1

  discard_on StandardError do |job, error|
    ErrorReporting.report("Comms::SendCampaignBatchJob", error)
    campaign = EmailCampaign.find_by(id: job.arguments.first)
    campaign.update_columns(status: "failed", updated_at: Time.current) if campaign&.sending?
  end

  def perform(campaign_id)
    campaign = EmailCampaign.find_by(id: campaign_id)
    return unless campaign&.sending?

    batch = campaign.email_campaign_recipients.where(status: "queued").order(:id).limit(BATCH_SIZE).to_a
    if batch.empty?
      self.class.finalize(campaign)
      return
    end

    batch.each do |recipient|
      claimed = EmailCampaignRecipient.where(id: recipient.id, status: "queued")
                                      .update_all(status: "sending", updated_at: Time.current)
      next if claimed.zero?

      deliver(campaign, recipient)
      sleep THROTTLE
    end

    campaign.reload
    if campaign.cancelled?
      campaign.email_campaign_recipients.where(status: "queued")
              .update_all(status: "skipped", updated_at: Time.current)
      return
    end

    if campaign.email_campaign_recipients.where(status: "queued").exists?
      self.class.perform_later(campaign.id)
    else
      self.class.finalize(campaign)
    end
  end

  # Shared with the sweeper: a sending campaign with nothing left pending
  # closes as sent unless literally nothing went out and something failed.
  def self.finalize(campaign)
    return unless campaign.sending?

    scope = campaign.email_campaign_recipients
    any_out = scope.where(status: %w[sent delivered simulated]).exists?
    any_failed = scope.where(status: "failed").exists?
    final = !any_out && any_failed ? "failed" : "sent"
    campaign.update_columns(status: final, sent_at: Time.current, updated_at: Time.current)
  end

  private

  def deliver(campaign, recipient)
    if Comms::Delivery.live?
      Comms::CampaignMailer.campaign(recipient.id).deliver_now
      recipient.update_columns(status: "sent", sent_at: Time.current, updated_at: Time.current)
      EmailEvent.log!("sent", recipient: recipient, campaign: campaign)
    else
      recipient.update_columns(status: "simulated", sent_at: Time.current, updated_at: Time.current)
      EmailEvent.log!("simulated", recipient: recipient, campaign: campaign)
    end
  rescue => e
    ErrorReporting.report("Comms::SendCampaignBatchJob#deliver", e)
    recipient.update_columns(status: "failed", error: e.message.to_s.first(200), updated_at: Time.current)
    EmailEvent.log!("failed", recipient: recipient, campaign: campaign)
  end
end
