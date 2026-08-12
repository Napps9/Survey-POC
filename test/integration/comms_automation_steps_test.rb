require "test_helper"

# Drip sequences: steps anchor on the trigger event (not the previous
# step), carry :step:<id> keys so booking them never touches the primary's
# key, and deliver their own content through the same drain.
class CommsAutomationStepsTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @staff = User.create!(name: "Staff", email_address: "ca8-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: Time.current)
    @playverto.memberships.create!(user: @staff, role: "member")

    @automation = EmailAutomation.create!(
      name: "Welcome", trigger_type: "user_signed_up", subject: "Welcome!",
      delay_minutes: 0,
      design: { "blocks" => [ { "type" => "text", "text" => "Primary content" } ] }
    )
    @automation.update_columns(created_at: 1.day.ago)
    @automation.update!(enabled: true)
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  def make_step(delay: 0, subject: "Still there?", text: "Step content")
    @automation.email_automation_steps.create!(
      position: 1, delay_minutes: delay, subject: subject,
      design: { "blocks" => [ { "type" => "text", "text" => text } ] }
    )
  end

  test "steps book off the trigger anchor with distinct keys; primaries unchanged" do
    person = User.create!(name: "P", email_address: "ca8-p-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: 2.hours.ago)

    Comms::EnqueueAutomationRunsJob.perform_now
    primary = EmailAutomationRun.find_by(user_id: person.id, email_automation_step_id: nil)
    assert primary
    primary_key = primary.idempotency_key

    step = make_step(delay: 30) # 30 min after the event — already due
    Comms::EnqueueAutomationRunsJob.perform_now

    runs = EmailAutomationRun.where(user_id: person.id).order(:id)
    assert_equal 2, runs.count
    step_run = runs.find { |r| r.email_automation_step_id == step.id }
    assert step_run
    assert_equal "#{primary_key}:step:#{step.id}", step_run.idempotency_key
    assert_in_delta (person.email_verified_at + 30.minutes).to_i, step_run.scheduled_at.to_i, 1

    # The primary's key never changed — no re-send was booked.
    assert_equal primary_key, EmailAutomationRun.find_by(user_id: person.id,
                                                         email_automation_step_id: nil).idempotency_key

    # Sweep again: still exactly two runs.
    Comms::EnqueueAutomationRunsJob.perform_now
    assert_equal 2, EmailAutomationRun.where(user_id: person.id).count
  end

  test "a step run delivers the step's content and subject" do
    person = User.create!(name: "P", email_address: "ca8-d-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: 2.hours.ago)
    make_step(delay: 5, subject: "Follow-up subject", text: "The follow-up body")

    Comms::EnqueueAutomationRunsJob.perform_now
    drain_enqueued_jobs

    subjects = ActionMailer::Base.deliveries.select { |m| m.to == [ person.email_address ] }
                                            .map(&:subject).sort
    assert_equal [ "Follow-up subject", "Welcome!" ], subjects
    step_mail = ActionMailer::Base.deliveries.find { |m| m.subject == "Follow-up subject" }
    assert_includes step_mail.html_part.body.to_s, "The follow-up body"
    assert_not_includes step_mail.html_part.body.to_s, "Primary content"
  end

  test "an uncompiled step never books; a deleted step's runs skip" do
    person = User.create!(name: "P", email_address: "ca8-s-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD, email_verified_at: 2.hours.ago)
    empty_step = @automation.email_automation_steps.create!(position: 1, delay_minutes: 5,
                                                            subject: "S", design: { "blocks" => [] })

    Comms::EnqueueAutomationRunsJob.perform_now
    assert_not EmailAutomationRun.exists?(email_automation_step_id: empty_step.id)

    doomed = make_step(delay: 5)
    Comms::EnqueueAutomationRunsJob.perform_now
    run = EmailAutomationRun.find_by(email_automation_step_id: doomed.id, user_id: person.id)
    assert run
    doomed.destroy!

    drain_enqueued_jobs
    assert_equal "skipped", run.reload.status
  end

  test "the step builder surface: create, edit, autosave, delete" do
    sign_in @staff

    post comms_automation_steps_path(@automation)
    step = @automation.email_automation_steps.order(:id).last
    assert_redirected_to edit_comms_automation_step_path(@automation, step)
    assert_equal @automation.delay_minutes + 1440, step.delay_minutes

    follow_redirect!
    assert_response :success
    assert_match "comms-paper", response.body
    assert_match "Timing", response.body

    patch comms_automation_step_path(@automation, step),
          params: { subject: "Day two", delay_minutes: 2880,
                    design: { "blocks" => [ { "type" => "text", "text" => "Two days in" } ] } },
          as: :json
    step.reload
    assert_equal "Day two", step.subject
    assert_equal 2880, step.delay_minutes
    assert_includes step.compiled_html, "Two days in"

    delete comms_automation_step_path(@automation, step)
    assert_redirected_to edit_comms_automation_path(@automation)
    assert_not EmailAutomationStep.exists?(step.id)
  end
end
