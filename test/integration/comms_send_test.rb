require "test_helper"

# The send pipeline end to end: freeze-at-approval, recipient snapshot with
# dedup + suppression subtraction, batched delivery with claim-then-send,
# mid-flight cancellation, and the post-freeze-edit rule — the sent bytes
# are the approved bytes, never the live row.
class CommsSendTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @staff = User.create!(name: "Staff", email_address: "cs-staff-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: Time.current)
    @playverto.memberships.create!(user: @staff, role: "member")
    sign_in @staff

    @list = EmailList.create!(name: "Send list")
    3.times { |i| @list.email_list_contacts.create!(email: "send-#{i}-#{SecureRandom.hex(2)}@example.org") }

    post comms_campaigns_path
    @campaign = EmailCampaign.order(:id).last
    patch comms_campaign_path(@campaign), params: {
      subject: "Hello there",
      audience: { kind: "list", list_id: @list.id },
      design: { "blocks" => [
        { "type" => "heading", "text" => "Hi" },
        { "type" => "button", "text" => "Go", "href" => "https://dest.example/page" }
      ] }
    }, as: :json
    @campaign.reload
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  test "freeze refuses a blank subject, warnings, and an empty audience" do
    @campaign.update!(subject: "")
    post send_now_comms_campaign_path(@campaign)
    assert_redirected_to edit_comms_campaign_path(@campaign)
    assert_match(/subject/i, flash[:alert])
    assert @campaign.reload.draft?

    @campaign.update!(subject: "Ok", design: { "blocks" => [ { "type" => "image", "src" => "" } ] })
    post send_now_comms_campaign_path(@campaign)
    assert_match(/image/i, flash[:alert])

    @campaign.update!(design: { "blocks" => [ { "type" => "text", "text" => "x" } ] },
                      audience: { "kind" => "list", "list_id" => 999_999 })
    post send_now_comms_campaign_path(@campaign)
    assert_match(/audience/i, flash[:alert])
    assert @campaign.reload.draft?
  end

  test "send now freezes, snapshots recipients, delivers each once and finishes sent" do
    assert_enqueued_with(job: Comms::StartCampaignSendJob) do
      post send_now_comms_campaign_path(@campaign)
    end
    assert_equal I18n.t("flash.comms.send_started"), flash[:notice]
    @campaign.reload
    assert @campaign.scheduled?
    assert @campaign.compiled_html.present?
    assert @campaign.email_campaign_links.exists?
    assert_includes @campaign.compiled_html, "{{link:"

    assert_difference "ActionMailer::Base.deliveries.size", 3 do
      drain_enqueued_jobs
    end

    @campaign.reload
    assert @campaign.sent?
    assert_equal 3, @campaign.recipient_count
    assert_equal 3, @campaign.email_campaign_recipients.where(status: "sent").count

    mail = ActionMailer::Base.deliveries.last
    assert_equal "Hello there", mail.subject
    recipient = @campaign.email_campaign_recipients.find_by(email: mail.to.first)
    [ mail.html_part, mail.text_part ].each do |part|
      assert_includes part.body.to_s, recipient.token
    end
    assert_includes mail.html_part.body.to_s, "/e/o/#{recipient.token}"
    assert_includes mail.html_part.body.to_s, "/e/c/#{recipient.token}/"
    assert_not_includes mail.html_part.body.to_s, "{{unsubscribe_url}}"
    assert_not_includes mail.html_part.body.to_s, "{{link:"
    assert_equal "<#{comms_unsubscribe_url(token: recipient.token)}>", mail.header["List-Unsubscribe"].value
    assert_equal "List-Unsubscribe=One-Click", mail.header["List-Unsubscribe-Post"].value
  end

  test "edits after freeze do not change what is sent" do
    post send_now_comms_campaign_path(@campaign)
    @campaign.reload
    frozen_html = @campaign.compiled_html

    # The row is still editable while scheduled — mutate everything.
    @campaign.update!(subject: "EDITED LATE",
                      design: { "blocks" => [ { "type" => "text", "text" => "EDITED CONTENT" } ] })

    drain_enqueued_jobs

    mail = ActionMailer::Base.deliveries.last
    assert_equal "Hello there", mail.subject
    assert_not_includes mail.html_part.body.to_s, "EDITED CONTENT"
    assert_equal frozen_html, @campaign.reload.compiled_html
  end

  test "suppressed addresses are subtracted at snapshot time" do
    suppressed = @list.email_list_contacts.first.email
    EmailSuppression.record!(suppressed, reason: "unsubscribe")

    post send_now_comms_campaign_path(@campaign)
    drain_enqueued_jobs

    @campaign.reload
    assert_equal 2, @campaign.recipient_count
    assert_not_includes @campaign.email_campaign_recipients.pluck(:email), suppressed
  end

  test "a big audience chains batches and delivers everyone exactly once" do
    emails = (1..60).map { |i| "bulk-#{i}@example.org" }
    now = Time.current
    EmailListContact.insert_all(emails.map { |e|
      { email_list_id: @list.id, email: e, created_at: now, updated_at: now }
    })

    post send_now_comms_campaign_path(@campaign)
    drain_enqueued_jobs # runs the start job + every chained batch job

    @campaign.reload
    assert @campaign.sent?
    assert_equal 63, @campaign.email_campaign_recipients.where(status: "sent").count
    assert_equal 63, ActionMailer::Base.deliveries.size
    assert_equal 63, ActionMailer::Base.deliveries.map(&:to).flatten.uniq.size
  end

  test "cancel mid-send skips the queued remainder and stays cancelled" do
    post send_now_comms_campaign_path(@campaign)
    perform_enqueued_jobs(only: Comms::StartCampaignSendJob)
    @campaign.reload
    assert @campaign.sending?

    post cancel_send_comms_campaign_path(@campaign)
    assert_equal I18n.t("flash.comms.send_cancelled"), flash[:notice]

    drain_enqueued_jobs # the batch job fires against a cancelled campaign

    @campaign.reload
    assert @campaign.cancelled?
    assert_equal 0, ActionMailer::Base.deliveries.size
    assert_equal 3, @campaign.email_campaign_recipients.where(status: "skipped").count
  end

  test "simulated mode runs the whole pipeline without delivering" do
    stub_method(Comms::Delivery, :live?, false) do
      post send_now_comms_campaign_path(@campaign)
      drain_enqueued_jobs
    end

    @campaign.reload
    assert @campaign.sent?
    assert_equal 0, ActionMailer::Base.deliveries.size
    assert_equal 3, @campaign.email_campaign_recipients.where(status: "simulated").count
    assert_equal 3, EmailEvent.where(kind: "simulated", email_campaign_id: @campaign.id).count
  end

  test "test send mails the current draft to the author with tracking stubbed" do
    assert_difference "ActionMailer::Base.deliveries.size", 1 do
      post test_send_comms_campaign_path(@campaign)
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ @staff.email_address ], mail.to
    assert_match(/\[Test\]/, mail.subject)
    assert_not_includes mail.html_part.body.to_s, "{{unsubscribe_url}}"
    assert_not_includes mail.html_part.body.to_s, "/e/o/"
  end

  test "status endpoint reports counts for the polling panel" do
    post send_now_comms_campaign_path(@campaign)
    drain_enqueued_jobs

    get status_comms_campaign_path(@campaign)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "sent", body["status"]
    assert_equal 3, body["counts"]["sent"]
  end
end
