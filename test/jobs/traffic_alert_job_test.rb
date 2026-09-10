require "test_helper"

class TrafficAlertJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  def setup
    @org = Organisation.create!(name: "Traffic Org", slug: "ta-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Busy Verto", theme: "T", audience_age: "all",
                                   key_insight: "x", default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "open_ended", "text" => "Why?" } ])
  end

  def responses!(n, age: 1.minute, survey: @survey)
    n.times do
      r = survey.responses.create!(session_token: SecureRandom.uuid, status: "started")
      r.update_columns(created_at: age.ago)
    end
  end

  def with_env(**vars)
    previous = vars.keys.index_with { |k| ENV[k.to_s] }
    vars.each { |k, v| ENV[k.to_s] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k.to_s] = v }
  end

  test "sends nothing when no recipients are configured" do
    responses!(400)

    with_env(TRAFFIC_ALERT_EMAILS: nil, TRAFFIC_ALERT_PER_MINUTE: "1") do
      assert_no_emails { TrafficAlertJob.perform_now }
    end
  end

  test "sends nothing when the rate is under the threshold" do
    responses!(10)

    with_env(TRAFFIC_ALERT_EMAILS: "ops@example.com", TRAFFIC_ALERT_PER_MINUTE: "10") do
      assert_no_emails { TrafficAlertJob.perform_now }
    end
  end

  test "emails the configured recipients once the rate crosses the threshold" do
    # 300 in the 15-minute window is 20 a minute, over a threshold of 10.
    responses!(300)

    with_env(TRAFFIC_ALERT_EMAILS: "ops@example.com, second@example.com",
             TRAFFIC_ALERT_PER_MINUTE: "10") do
      assert_emails(1) { TrafficAlertJob.perform_now }
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "ops@example.com", "second@example.com" ], mail.to
    assert_match "300 responses", mail.subject
    assert_match "20 a minute", mail.subject
    assert_match "Busy Verto", mail.body.encoded
    assert_match "Traffic Org", mail.body.encoded
  end

  test "responses older than the window do not count towards the rate" do
    responses!(300, age: 2.hours)

    with_env(TRAFFIC_ALERT_EMAILS: "ops@example.com", TRAFFIC_ALERT_PER_MINUTE: "10") do
      assert_no_emails { TrafficAlertJob.perform_now }
    end
  end

  test "a malformed threshold falls back to the default rather than raising" do
    with_env(TRAFFIC_ALERT_PER_MINUTE: "not-a-number") do
      assert_equal TrafficAlertJob::DEFAULT_PER_MINUTE, TrafficAlertJob.threshold_per_minute
    end
  end

  test "the window matches the recurring schedule, so runs neither overlap nor gap" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "traffic_alert", "schedule")

    assert_equal "TrafficAlertJob", YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "traffic_alert", "class")
    assert_equal "every #{(TrafficAlertJob::WINDOW / 60).to_i} minutes", schedule
  end
end
