require "test_helper"

# Completion time + device type on a response: stamped once on first touch,
# never moved by a refresh or a replayed offline submit, and surfaced in the
# export so a researcher can actually use them.
class ResponseMetadataTest < ActionDispatch::IntegrationTest
  # Full, realistic UA strings: ApplicationController runs Rails' `allow_browser
  # versions: :modern` gate, which 406s anything it can't read a version out of.
  IPHONE  = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
            "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1".freeze
  DESKTOP = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
            "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36".freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "meta-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    @token = SecureRandom.uuid
  end

  def post_json(path, body, user_agent: DESKTOP)
    post path, params: body.to_json,
         headers: { "Content-Type" => "application/json", "User-Agent" => user_agent }
  end

  def progress(answers = { "0" => { "value" => "Yes" } }, **opts)
    post_json progress_survey_path(@survey.publish_token),
              { session_token: @token, answers: answers }, **opts
  end

  def submit(answers = { "0" => { "value" => "Yes" } }, **opts)
    post_json submit_survey_path(@survey.publish_token),
              { session_token: @token, answers: answers }, **opts
  end

  test "first progress stamps started_at and the device bucket" do
    progress(user_agent: IPHONE)
    assert_response :success

    resp = Response.find_by!(session_token: @token)
    assert_not_nil resp.started_at
    assert_equal "phone", resp.device_kind
  end

  test "a later progress does not move started_at or relabel the device" do
    progress(user_agent: IPHONE)
    resp    = Response.find_by!(session_token: @token)
    started = resp.started_at

    travel 30.seconds do
      # Same session on a different UA (a shared device, or a spoofed replay)
      # must not overwrite what the first touch recorded.
      progress({ "0" => { "value" => "No" } }, user_agent: DESKTOP)
    end

    resp.reload
    assert_equal started.to_i, resp.started_at.to_i
    assert_equal "phone", resp.device_kind
  end

  test "submit stamps completed_at and the duration computes" do
    progress
    resp = Response.find_by!(session_token: @token)
    resp.update_columns(started_at: 45.seconds.ago)

    submit
    assert_response :success

    resp.reload
    assert_not_nil resp.completed_at
    assert_equal "completed", resp.status
    assert_in_delta 45, resp.duration_seconds, 5
  end

  test "a submit with no prior progress still gets both ends stamped" do
    submit(user_agent: IPHONE)
    assert_response :success

    resp = Response.find_by!(session_token: @token)
    assert_not_nil resp.started_at
    assert_not_nil resp.completed_at
    assert_equal "phone", resp.device_kind
    assert_not_nil resp.duration_seconds
  end

  test "a replayed submit does not move completed_at" do
    submit
    resp  = Response.find_by!(session_token: @token)
    first = resp.completed_at

    travel 2.minutes do
      submit # the offline queue draining a duplicate
    end

    assert_equal first.to_i, resp.reload.completed_at.to_i
  end

  test "duration_seconds is nil until both ends exist" do
    progress
    assert_nil Response.find_by!(session_token: @token).duration_seconds
  end

  test "the response export carries duration and device columns" do
    progress(user_agent: IPHONE)
    Response.find_by!(session_token: @token).update_columns(started_at: 20.seconds.ago)
    submit(user_agent: IPHONE)

    export = ResultsExport.new(survey: @survey, responses: @survey.responses, aggregated: [])
    rows   = []
    export.each_row(summary: false) { |row| rows << row }

    assert_equal "Duration (seconds)", rows.first[4]
    assert_equal "Device", rows.first[5]
    assert_in_delta 20, rows.second[4].to_i, 5
    assert_equal "phone", rows.second[5]
  end

  test "DeviceKind buckets the user agents we care about" do
    assert_equal "phone",   DeviceKind.from(IPHONE)
    assert_equal "desktop", DeviceKind.from(DESKTOP)
    assert_equal "tablet",  DeviceKind.from("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) Mobile/15E148")
    assert_equal "phone",   DeviceKind.from("Mozilla/5.0 (Linux; Android 14; Pixel 8) Mobile Safari/537.36")
    assert_equal "tablet",  DeviceKind.from("Mozilla/5.0 (Linux; Android 14; SM-X200) Safari/537.36")
    assert_equal "unknown", DeviceKind.from(nil)
    assert_equal "unknown", DeviceKind.from("")
  end
end
