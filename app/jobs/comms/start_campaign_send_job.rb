# Flips an approved campaign to sending: resolves the FROZEN audience (the
# snapshot, never the live row), snapshots one recipient row per address
# with a deterministic A/B variant, and hands off to the batch sender.
#
# Idempotence guard: only a `scheduled` campaign whose time has come moves.
# A cancelled-then-fired stale job (cancel schedule leaves queued jobs
# behind), a double enqueue from the sweeper, or a not-yet-due firing all
# no-op here — this is how "cancel schedule" works without deleting jobs.
class Comms::StartCampaignSendJob < ApplicationJob
  queue_as :default

  discard_on StandardError do |job, error|
    ErrorReporting.report("Comms::StartCampaignSendJob", error)
    campaign = EmailCampaign.find_by(id: job.arguments.first)
    campaign.update_columns(status: "failed", updated_at: Time.current) if campaign&.scheduled?
  end

  def perform(campaign_id)
    campaign = EmailCampaign.find_by(id: campaign_id)
    return unless campaign&.scheduled?
    return if campaign.scheduled_for.present? && campaign.scheduled_for > 30.seconds.from_now

    snapshot = campaign.scheduled_snapshot || {}
    rows = Comms::AudienceResolver.resolve(snapshot["audience"])
    if rows.empty?
      # The audience emptied between approval and send (unsubscribes, a
      # deleted list) — an honest failure, not a silent no-send.
      campaign.update_columns(status: "failed", updated_at: Time.current)
      return
    end

    # The split is decided once, here: recipients ordered by normalized
    # email, variant = index % (subject + extra variants). Deterministic and
    # test-pinned.
    variants = 1 + Array(snapshot["subject_variants"]).size
    now = Time.current
    data = rows.sort_by { |r| r[:email] }.each_with_index.map do |r, i|
      { email_campaign_id: campaign.id, email: r[:email], name: r[:name],
        user_id: r[:user_id], email_list_contact_id: r[:contact_id],
        token: SecureRandom.base58(24), status: "queued",
        subject_variant: i % variants, created_at: now, updated_at: now }
    end
    EmailCampaignRecipient.insert_all(data, unique_by: [ :email_campaign_id, :email ])

    campaign.update_columns(status: "sending",
                            recipient_count: campaign.email_campaign_recipients.count,
                            updated_at: now)
    Comms::SendCampaignBatchJob.perform_later(campaign.id)
  end
end
