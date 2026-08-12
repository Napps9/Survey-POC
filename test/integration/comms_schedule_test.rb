require "test_helper"

# Scheduling: freeze + set(wait_until:), cancellation that survives the
# already-queued job (its guard makes the stale firing a no-op), and the
# deterministic A/B split with per-variant subjects in the delivered mail.
class CommsScheduleTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @staff = User.create!(name: "Staff", email_address: "sch-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: Time.current)
    @playverto.memberships.create!(user: @staff, role: "member")
    sign_in @staff

    @list = EmailList.create!(name: "Sched list")
    6.times { |i| @list.email_list_contacts.create!(email: "sch-#{i}@example.org") }

    post comms_campaigns_path
    @campaign = EmailCampaign.order(:id).last
    patch comms_campaign_path(@campaign), params: {
      subject: "Subject A",
      audience: { kind: "list", list_id: @list.id },
      design: { "blocks" => [ { "type" => "text", "text" => "hello" } ] }
    }, as: :json
    @campaign.reload
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  test "scheduling freezes and enqueues the job at the booked time" do
    at = 2.hours.from_now.change(usec: 0)

    assert_enqueued_with(job: Comms::StartCampaignSendJob, at: at) do
      post schedule_comms_campaign_path(@campaign), params: { scheduled_at: at.utc.iso8601 }
    end
    assert_equal I18n.t("flash.comms.schedule_set"), flash[:notice]

    @campaign.reload
    assert @campaign.scheduled?
    assert_in_delta at.to_i, @campaign.scheduled_for.to_i, 1
    assert @campaign.compiled_html.present?
    assert_equal "Subject A", @campaign.scheduled_snapshot["subject"]
  end

  test "a past or junk time is refused" do
    post schedule_comms_campaign_path(@campaign), params: { scheduled_at: 1.hour.ago.utc.iso8601 }
    assert @campaign.reload.draft?
    assert flash[:alert].present?

    post schedule_comms_campaign_path(@campaign), params: { scheduled_at: "whenever" }
    assert @campaign.reload.draft?
  end

  test "cancelling reverts to draft and the stale job fires as a no-op" do
    post schedule_comms_campaign_path(@campaign),
         params: { scheduled_at: 1.hour.from_now.utc.iso8601 }
    assert @campaign.reload.scheduled?

    post cancel_schedule_comms_campaign_path(@campaign)
    @campaign.reload
    assert @campaign.draft?
    assert_nil @campaign.compiled_html
    assert_nil @campaign.scheduled_snapshot
    assert_equal 0, @campaign.email_campaign_links.count

    # The queued job still exists — firing it must change nothing.
    drain_enqueued_jobs
    @campaign.reload
    assert @campaign.draft?
    assert_equal 0, @campaign.email_campaign_recipients.count
    assert_equal 0, ActionMailer::Base.deliveries.size
  end

  test "a due scheduled send goes out with the frozen content" do
    post schedule_comms_campaign_path(@campaign),
         params: { scheduled_at: 90.seconds.from_now.utc.iso8601 }
    @campaign.reload.update_columns(scheduled_for: 1.minute.ago) # time passes

    drain_enqueued_jobs

    @campaign.reload
    assert @campaign.sent?
    assert_equal 6, ActionMailer::Base.deliveries.size
  end

  test "the A/B split is deterministic and mails the right variant subjects" do
    patch comms_campaign_path(@campaign),
          params: { subject_variants: [ "Subject B", "Subject C", "", "Subject E (trimmed)" ] }, as: :json
    assert_equal [ "Subject B", "Subject C", "Subject E (trimmed)" ], @campaign.reload.subject_variants

    patch comms_campaign_path(@campaign), params: { subject_variants: [ "Subject B", "Subject C" ] }, as: :json
    post send_now_comms_campaign_path(@campaign)
    drain_enqueued_jobs

    @campaign.reload
    assert @campaign.sent?

    # 6 recipients over 3 subjects: sorted emails get variants 0,1,2,0,1,2.
    expected = @campaign.email_campaign_recipients.sort_by(&:email).map.with_index { |_r, i| i % 3 }
    actual = @campaign.email_campaign_recipients.sort_by(&:email).map(&:subject_variant)
    assert_equal expected, actual

    subjects = ActionMailer::Base.deliveries.map(&:subject).tally
    assert_equal({ "Subject A" => 2, "Subject B" => 2, "Subject C" => 2 }, subjects)
  end

  test "the report tiles render on a finished campaign" do
    post send_now_comms_campaign_path(@campaign)
    drain_enqueued_jobs
    recipient = @campaign.email_campaign_recipients.first
    recipient.record_open!

    get edit_comms_campaign_path(@campaign)
    assert_response :success
    assert_match "Campaign status", response.body
    assert_match "opened", response.body
  end
end
