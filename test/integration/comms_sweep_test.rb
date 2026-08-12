require "test_helper"

# The sweeper makes watchdog restarts honest: lost scheduled jobs are
# re-enqueued, recipients stuck mid-claim are reaped (never resent), stalled
# sends are re-poked, finished ones finalized — and running it twice changes
# nothing.
class CommsSweepTest < ActionDispatch::IntegrationTest
  def frozen_campaign(scheduled_for: nil)
    list = EmailList.create!(name: "L-#{SecureRandom.hex(2)}")
    list.email_list_contacts.create!(email: "sw-#{SecureRandom.hex(3)}@example.org")
    campaign = EmailCampaign.create!(title: "T", subject: "S",
                                     audience: { "kind" => "list", "list_id" => list.id },
                                     design: { "blocks" => [ { "type" => "text", "text" => "x" } ] })
    result = Comms::CampaignFreezer.call(campaign, scheduled_for: scheduled_for)
    assert result.ok?, result.error
    campaign.reload
  end

  test "a due scheduled campaign whose job vanished is re-enqueued" do
    campaign = frozen_campaign(scheduled_for: 1.minute.ago)

    assert_enqueued_with(job: Comms::StartCampaignSendJob) { Comms::SweepJob.perform_now }
    drain_enqueued_jobs
    assert campaign.reload.sent?
  end

  test "a future scheduled campaign is left alone" do
    campaign = frozen_campaign(scheduled_for: 1.hour.from_now)

    Comms::SweepJob.perform_now
    drain_enqueued_jobs
    assert campaign.reload.scheduled?
  end

  test "recipients stuck mid-claim are reaped as failed, not resent" do
    campaign = frozen_campaign
    Comms::StartCampaignSendJob.perform_now(campaign.id)
    campaign.reload
    stuck = campaign.email_campaign_recipients.first
    stuck.update_columns(status: "sending", updated_at: 20.minutes.ago)
    campaign.update_columns(updated_at: 20.minutes.ago)
    clear_enqueued_jobs

    Comms::SweepJob.perform_now
    drain_enqueued_jobs

    stuck.reload
    assert_equal "failed", stuck.status
    assert_equal 0, ActionMailer::Base.deliveries.size
    # Its only recipient failed and nothing went out — an honest failure.
    assert campaign.reload.failed?
  end

  test "a stalled send with queued recipients is re-poked to completion" do
    campaign = frozen_campaign
    Comms::StartCampaignSendJob.perform_now(campaign.id)
    campaign.update_columns(updated_at: 20.minutes.ago)
    clear_enqueued_jobs # the batch job was "lost"

    Comms::SweepJob.perform_now
    drain_enqueued_jobs

    campaign.reload
    assert campaign.sent?
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "sweeping twice is a no-op" do
    campaign = frozen_campaign
    Comms::StartCampaignSendJob.perform_now(campaign.id)
    campaign.update_columns(updated_at: 20.minutes.ago)
    clear_enqueued_jobs

    Comms::SweepJob.perform_now
    drain_enqueued_jobs
    deliveries = ActionMailer::Base.deliveries.size

    Comms::SweepJob.perform_now
    drain_enqueued_jobs
    assert_equal deliveries, ActionMailer::Base.deliveries.size
  end
end
