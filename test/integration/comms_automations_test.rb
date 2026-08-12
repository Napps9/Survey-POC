require "test_helper"

# The automations engine end to end: the enqueue sweep is idempotent (the
# ledger's unique key, not luck), suppressed/unsubscribed subjects never
# book, the send worker drains due runs once, and the builder surface is
# gated like everything else under /comms.
class CommsAutomationsTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @staff = User.create!(name: "Staff", email_address: "ca7-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: Time.current)
    @playverto.memberships.create!(user: @staff, role: "member")
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  def make_automation(enabled: true, **attrs)
    automation = EmailAutomation.create!(
      { name: "Welcome", trigger_type: "user_signed_up", subject: "Welcome!",
        design: { "blocks" => [ { "type" => "text", "text" => "Hi there" } ] } }.merge(attrs)
    )
    automation.tap { |a| a.update_columns(created_at: 1.day.ago) }
    automation.update!(enabled: true) if enabled
    automation
  end

  test "the enqueue sweep books each subject once — running twice changes nothing" do
    automation = make_automation
    newcomer = User.create!(name: "N", email_address: "ca7-new-#{SecureRandom.hex(3)}@test.com",
                            password: PASSWORD, email_verified_at: 1.hour.ago)

    Comms::EnqueueAutomationRunsJob.perform_now
    first_count = EmailAutomationRun.where(email_automation_id: automation.id).count
    assert_operator first_count, :>=, 1
    assert EmailAutomationRun.exists?(user_id: newcomer.id)

    Comms::EnqueueAutomationRunsJob.perform_now
    assert_equal first_count, EmailAutomationRun.where(email_automation_id: automation.id).count
  end

  test "suppressed and unverified subjects are never booked" do
    make_automation
    suppressed = User.create!(name: "S", email_address: "ca7-sup-#{SecureRandom.hex(3)}@test.com",
                              password: PASSWORD, email_verified_at: 1.hour.ago)
    EmailSuppression.record!(suppressed.email_address, reason: "unsubscribe")
    unverified = User.create!(name: "U", email_address: "ca7-unv-#{SecureRandom.hex(3)}@test.com",
                              password: PASSWORD)

    Comms::EnqueueAutomationRunsJob.perform_now

    assert_not EmailAutomationRun.exists?(user_id: suppressed.id)
    assert_not EmailAutomationRun.exists?(user_id: unverified.id)
  end

  test "org conditions restrict who a user-anchored trigger fires for" do
    org = Organisation.create!(name: "In", slug: "ca7-in-#{SecureRandom.hex(3)}")
    make_automation(conditions: { "organisation_ids" => [ org.id ] })

    insider = User.create!(name: "I", email_address: "ca7-in-#{SecureRandom.hex(3)}@test.com",
                           password: PASSWORD, email_verified_at: 1.hour.ago)
    org.memberships.create!(user: insider, role: "member")
    outsider = User.create!(name: "O", email_address: "ca7-out-#{SecureRandom.hex(3)}@test.com",
                            password: PASSWORD, email_verified_at: 1.hour.ago)

    Comms::EnqueueAutomationRunsJob.perform_now

    assert EmailAutomationRun.exists?(user_id: insider.id)
    assert_not EmailAutomationRun.exists?(user_id: outsider.id)
  end

  test "due runs deliver once with unsubscribe and pixel; late suppression wins" do
    automation = make_automation
    subject_user = User.create!(name: "R", email_address: "ca7-rcv-#{SecureRandom.hex(3)}@test.com",
                                password: PASSWORD, email_verified_at: 1.hour.ago)
    late = User.create!(name: "L", email_address: "ca7-late-#{SecureRandom.hex(3)}@test.com",
                        password: PASSWORD, email_verified_at: 1.hour.ago)

    Comms::EnqueueAutomationRunsJob.perform_now
    EmailSuppression.record!(late.email_address, reason: "unsubscribe")

    drain_enqueued_jobs

    run = EmailAutomationRun.find_by(user_id: subject_user.id)
    assert_equal "sent", run.status
    assert_equal "suppressed", EmailAutomationRun.find_by(user_id: late.id).status

    mail = ActionMailer::Base.deliveries.find { |m| m.to == [ subject_user.email_address ] }
    assert mail, "subject should have been mailed"
    assert_equal "Welcome!", mail.subject
    assert_includes mail.html_part.body.to_s, "/e/u/#{run.token}"
    assert_includes mail.html_part.body.to_s, "/e/o/#{run.token}"
    assert_not_includes mail.html_part.body.to_s, "{{unsubscribe_url}}"

    # Drain again: nothing new goes out.
    deliveries = ActionMailer::Base.deliveries.size
    Comms::SendAutomationRunsJob.perform_now
    assert_equal deliveries, ActionMailer::Base.deliveries.size
  end

  test "automation unsubscribe suppresses and future sweeps skip the address" do
    automation = make_automation
    person = User.create!(name: "P", email_address: "ca7-p-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: 1.hour.ago)
    Comms::EnqueueAutomationRunsJob.perform_now
    drain_enqueued_jobs
    run = EmailAutomationRun.find_by(user_id: person.id)

    get comms_unsubscribe_path(token: run.token)
    assert_response :success
    post comms_unsubscribe_path(token: run.token)
    assert_response :success
    assert EmailSuppression.exists?(email: person.email_address)

    # The open pixel logs an event for automation runs too.
    get comms_open_path(token: run.token)
    assert_response :success
    assert EmailEvent.exists?(kind: "open", email_automation_run_id: run.id)
  end

  test "an unsendable automation cannot be enabled; editing it off disables it" do
    sign_in @staff
    automation = EmailAutomation.create!(name: "Empty", design: { "blocks" => [] })

    post toggle_comms_automation_path(automation)
    assert flash[:alert].present?
    assert_not automation.reload.enabled?

    good = make_automation
    assert good.reload.enabled?
    patch comms_automation_path(good), params: { subject: "" }, as: :json
    assert_not good.reload.enabled?
  end

  test "the builder surface works: create, edit, autosave name via title, test send" do
    sign_in @staff

    post comms_automations_path
    automation = EmailAutomation.order(:id).last
    assert_redirected_to edit_comms_automation_path(automation)

    follow_redirect!
    assert_response :success
    assert_match "comms-paper", response.body
    assert_match "Trigger", response.body

    patch comms_automation_path(automation),
          params: { title: "Welcome flow", trigger_type: "user_inactive",
                    params: { inactive_days: 14 }, delay_minutes: 60 }, as: :json
    automation.reload
    assert_equal "Welcome flow", automation.name
    assert_equal "user_inactive", automation.trigger_type
    assert_equal 14, automation.params["inactive_days"]
    assert_equal 60, automation.delay_minutes

    assert_difference "ActionMailer::Base.deliveries.size", 1 do
      post test_send_comms_automation_path(automation)
    end

    delete session_path
    outsider = User.create!(name: "Out", email_address: "ca7-o-#{SecureRandom.hex(3)}@test.com",
                            password: PASSWORD)
    Organisation.create!(name: "X", slug: "ca7-x-#{SecureRandom.hex(3)}")
                .memberships.create!(user: outsider, role: "admin")
    sign_in outsider
    get comms_automations_path
    assert_response :not_found
  rescue ActionController::RoutingError
    assert true
  end
end
