require "test_helper"

# Thursday's generator. The invariant under test throughout: it produces a
# reviewable DRAFT and never a send.
class CommsNewsletterTest < ActionDispatch::IntegrationTest
  THURSDAY = Date.new(2026, 8, 13)
  WEEK     = Date.new(2026, 8, 10)

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @staff = User.create!(name: "Staff", email_address: "nl-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword", email_verified_at: Time.current)
    @playverto.memberships.create!(user: @staff, role: "admin")
  end

  WRITTEN_COPY = {
    "subject"   => "Imports that keep their columns straight",
    "preheader" => "And a clearer results page.",
    "intro"     => "Here's what changed this week.",
    "items"     => [ { "title" => "Imports keep their columns straight",
                       "body"  => "Your uploads land where you expect them to." } ],
    "cta_label" => "Build your next Verto",
    "sign_off"  => "Tell us what you'd like next.",
    "source"    => "claude"
  }.freeze

  # No network, no Claude: the generator's own logic is what's under test.
  # `copy: nil` stands for a writer that couldn't produce anything.
  def run_job(commits: [ raw_commit("The importer learns to count", "Why it mattered.") ],
              copy: WRITTEN_COPY)
    # The fake is wrapped in a lambda because stub_method treats any callable
    # return value as the implementation — and FakeWriter responds to #call.
    stub_method(Comms::GithubCommits, :since, commits) do
      stub_method(NewsletterWriter, :new, ->(*_a, **_k) { FakeWriter.new(copy) }) do
        Comms::GenerateNewsletterJob.perform_now(THURSDAY)
      end
    end
  end

  class FakeWriter
    def initialize(copy) = @copy = copy
    def call(_commits, week:) = @copy
  end

  def raw_commit(subject, body = "")
    message = body.present? ? "#{subject}\n\n#{body}" : subject
    { "sha" => SecureRandom.hex(20),
      "commit" => { "message" => message, "author" => { "date" => "2026-08-11T09:00:00Z" } } }
  end

  test "generates one draft for the week, addressed to the Early adopters list" do
    assert_difference -> { EmailCampaign.count }, 1 do
      run_job
    end

    campaign = EmailCampaign.find_by(newsletter_week: WEEK)
    assert campaign
    assert_equal "draft", campaign.status
    assert_equal "Newsletter — week of 10 August 2026", campaign.title
    assert_equal WRITTEN_COPY["subject"], campaign.subject
    assert_equal WRITTEN_COPY["preheader"], campaign.preheader

    list = EmailList.find_by(name: Comms::GenerateNewsletterJob::LIST_NAME)
    assert list, "the list is created if it doesn't exist yet"
    assert_equal({ "kind" => "list", "list_id" => list.id }, campaign.audience)
  end

  test "IT NEVER SENDS: draft status, nothing frozen, no send job enqueued" do
    assert_no_enqueued_jobs only: [ Comms::StartCampaignSendJob, Comms::SendCampaignBatchJob ] do
      run_job
    end

    campaign = EmailCampaign.find_by(newsletter_week: WEEK)
    assert_equal "draft", campaign.status
    assert_nil campaign.compiled_html
    assert_nil campaign.compiled_text
    assert_nil campaign.scheduled_snapshot
    assert_equal 0, campaign.email_campaign_recipients.count

    # The suggested Monday is parked on the draft, where the sweeper cannot
    # see it — its due-campaign pass is scoped to `status: "scheduled"`.
    assert_equal Date.new(2026, 8, 17), campaign.scheduled_for.to_date
    assert_no_enqueued_jobs only: Comms::StartCampaignSendJob do
      Comms::SweepJob.perform_now
    end
    assert_equal "draft", campaign.reload.status
  end

  test "running twice produces one draft" do
    run_job
    assert_no_difference -> { EmailCampaign.count } do
      run_job
    end
    assert_equal 1, EmailCampaign.where(newsletter_week: WEEK).count
  end

  test "the generated document is sendable as-is once an audience exists" do
    run_job
    campaign = EmailCampaign.find_by(newsletter_week: WEEK)
    assert_equal [], campaign.warnings, "a draft the owner cannot freeze is worthless"

    list = EmailList.find_by(name: Comms::GenerateNewsletterJob::LIST_NAME)
    list.email_list_contacts.create!(email: "reader@example.com", name: "Reader")
    list.recount!

    result = Comms::CampaignFreezer.call(campaign.reload, scheduled_for: 1.day.from_now)
    assert result.ok?, result.error
    assert_includes campaign.reload.compiled_html, "Projects"
  end

  test "the Projects placeholder is present and unmistakable" do
    run_job
    doc = EmailCampaign.find_by(newsletter_week: WEEK).document
    callout = doc["blocks"].find { |b| b["type"] == "callout" }
    assert callout
    assert_equal Comms::NewsletterDocument::PROJECTS_HEADING, callout["eyebrow"]
    assert_equal Comms::NewsletterDocument::PROJECTS_PLACEHOLDER, callout["text"]
  end

  test "falls back to commit subjects when Claude is unavailable" do
    run_job(copy: nil)
    campaign = EmailCampaign.find_by(newsletter_week: WEEK)

    assert_includes campaign.subject, "What's new in VertoNow"
    titles = campaign.document["blocks"].select { |b| b["type"] == "feature" }.map { |b| b["text"] }
    assert_includes titles, "The importer learns to count"
    assert_equal [], campaign.warnings
  end

  test "a week with no commits, or an unreachable GitHub, still leaves a draft" do
    run_job(commits: [])
    campaign = EmailCampaign.find_by(newsletter_week: WEEK)
    assert campaign, "Thursday always produces something reviewable"
    assert_equal [], campaign.warnings
  end

  test "notifies the Comms team with what still needs doing" do
    perform_enqueued_jobs { run_job }

    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.to, @staff.email_address
    assert_includes mail.subject, "Draft ready"
    body = mail.body.to_s
    assert_includes body, "Fill in the Projects section"
    assert_includes body, "audience is EMPTY", "an empty list is a blocked send — say so"
    assert_includes body, "/comms/campaigns/"
  end

  test "a generated draft is marked for review in the index and the builder" do
    run_job
    campaign = EmailCampaign.find_by(newsletter_week: WEEK)
    assert campaign.newsletter?

    post session_path, params: { email_address: @staff.email_address, password: "verylongpassword" }
    get comms_path
    assert_response :success
    assert_match "Needs review", response.body

    get edit_comms_campaign_path(campaign)
    assert_response :success
    assert_match "Fill in the Projects section before you book it", response.body
    # The suggested Monday seeds the schedule input, so booking is one click.
    assert_match campaign.scheduled_for.utc.iso8601, response.body
  end

  test "a hand-built campaign carries no newsletter markings" do
    campaign = EmailCampaign.create!(title: "Hand-built", design: Comms::EmailDocument.starter_document)
    assert_not campaign.newsletter?

    post session_path, params: { email_address: @staff.email_address, password: "verylongpassword" }
    get edit_comms_campaign_path(campaign)
    assert_response :success
    assert_no_match "Fill in the Projects section", response.body
  end

  test "the notification reports the real audience size once the list has contacts" do
    list = EmailList.create!(name: Comms::GenerateNewsletterJob::LIST_NAME)
    list.email_list_contacts.create!(email: "reader@example.com", name: "Reader")
    list.recount!

    perform_enqueued_jobs { run_job }
    body = ActionMailer::Base.deliveries.last.body.to_s
    assert_includes body, "Audience: 1 recipient"
    assert_not_includes body, "audience is EMPTY"
  end
end
