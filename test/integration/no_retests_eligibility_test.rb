require "test_helper"

# POST /play/:token/eligibility — the one place No retests answers a question
# about a code before anything is written, so the code step can stop a returner
# there instead of one card later. One shape: `blocked: true` only for a code
# with a COMPLETED run in the CURRENT wave; unknown, blank, earlier wave,
# unfinished, rule off, device basis, spent budget and any error all read
# `blocked: false`. Nothing is ever stored. Kept apart from /recall, whose
# contract is never to confirm a code at all.
class NoRetestsEligibilityTest < ActionDispatch::IntegrationTest
  def setup
    @org = Organisation.create!(name: "O", slug: "nre-#{SecureRandom.hex(3)}")
  end

  def survey(**attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ],
                         cards: [ { "type" => "yes_no", "cid" => "q1", "text" => "Q", "options" => %w[Yes No] } ],
                         no_retests: true, respondent_code_enabled: true,
                         publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def completed!(s, code:)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true,
                        completed_at: Time.current, respondent_code_digest: s.respondent_code_digest(code),
                        survey_wave_id: s.current_wave&.id)
  end

  def eligibility(s, code, token: SecureRandom.uuid)
    post eligibility_survey_path(s.publish_token),
         params: { session_token: token, respondent_code: code }.to_json,
         headers: { "Content-Type" => "application/json" }
    JSON.parse(response.body)
  end

  BLOCKED  = { "ok" => true, "blocked" => true }.freeze
  ADMITTED = { "ok" => true, "blocked" => false }.freeze

  test "a code with a completed run in the current wave is blocked; nothing else is" do
    s = survey
    completed!(s, code: "sam14")
    s.responses.create!(session_token: "half", status: "started", answered: true,
                        respondent_code_digest: s.respondent_code_digest("half-done"))

    assert_equal BLOCKED,  eligibility(s, "sam14")
    assert_equal BLOCKED,  eligibility(s, " Sam14 "), "normalised exactly like the write path"
    assert_equal ADMITTED, eligibility(s, "zx91q"), "an unknown code reads like any admitted one"
    assert_equal ADMITTED, eligibility(s, "")
    assert_equal ADMITTED, eligibility(s, "half-done"), "an unfinished run is not a run"
    assert_equal 2, s.responses.count, "the probe never writes a row"
  end

  test "a code completed only in an earlier wave is admitted — until it finishes the new one" do
    s = survey
    completed!(s, code: "sam14")
    s.start_next_wave!

    assert_equal ADMITTED, eligibility(s, "sam14")
    completed!(s, code: "sam14")
    assert_equal BLOCKED, eligibility(s, "sam14")
  end

  test "rule off or device basis: always admitted, same shape" do
    off = survey(no_retests: false)
    completed!(off, code: "sam14")
    assert_equal ADMITTED, eligibility(off, "sam14")

    device = survey(respondent_code_enabled: false)
    assert_equal "device", device.retest_basis
    completed!(device, code: "sam14")
    assert_equal ADMITTED, eligibility(device, "sam14")
  end

  test "the body never carries the code or its digest, and the usual guards apply" do
    s = survey
    completed!(s, code: "sam14")
    eligibility(s, "sam14")
    assert_no_match(/sam14/, response.body)
    assert_no_match(/#{Regexp.escape(s.respondent_code_digest("sam14"))}/, response.body)

    post eligibility_survey_path("no-such-token"), params: "{}", headers: { "Content-Type" => "application/json" }
    assert_response :not_found

    s.update!(unpublished_at: Time.current)
    eligibility(s, "sam14")
    assert_response :gone
  end

  # ── The distinct-code budget ───────────────────────────────────────────────
  # The suite runs on the null cache store, where every budget is a no-op —
  # exactly like `rate_limit`. Swap in a real store to lock what it does.

  def with_memory_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous
  end

  test "over budget the oracle closes and the write path fails open" do
    with_memory_cache do
      s = survey
      completed!(s, code: "sam14")
      PlayerController::MAX_RETEST_CODES_PER_IP.times { |i| eligibility(s, "guess-#{i}") }

      assert_equal ADMITTED, eligibility(s, "sam14"),
                   "a completed code must read like any other once this caller has spent its budget"

      post submit_survey_path(s.publish_token),
           params: { session_token: "late", respondent_code: "sam14",
                     answers: { "0" => { "type" => "yes_no", "value" => "Yes" } } }.to_json,
           headers: { "Content-Type" => "application/json" }
      assert_response :success, "over budget the run is stored like a pre-feature retake, never refused"
      assert_equal 2, s.responses.count
    end
  end

  test "retrying one code is one guess, and a code first refused over budget stays refused" do
    with_memory_cache do
      s = survey
      completed!(s, code: "sam14")
      (PlayerController::MAX_RETEST_CODES_PER_IP * 2).times { eligibility(s, "same-guess") }
      assert_equal BLOCKED, eligibility(s, "sam14"), "a classroom retrying typos must not spend the budget"

      late = "fresh-#{PlayerController::MAX_RETEST_CODES_PER_IP + 4}"
      (PlayerController::MAX_RETEST_CODES_PER_IP + 5).times { |i| eligibility(s, "fresh-#{i}") }
      completed!(s, code: late)
      assert_equal ADMITTED, eligibility(s, late),
                   "the marker is written only for admitted codes — a retry must not slip past the ceiling"
    end
  end

  test "a legitimate run spends about two: the code step and the first write" do
    with_memory_cache do
      s = survey
      eligibility(s, "sam14", token: "t1")
      post submit_survey_path(s.publish_token),
           params: { session_token: "t1", respondent_code: "sam14",
                     answers: { "0" => { "type" => "yes_no", "value" => "Yes" } } }.to_json,
           headers: { "Content-Type" => "application/json" }
      assert_response :success
      assert_equal 1, Rails.cache.read("retest:#{s.id}:ip:127.0.0.1"), "same code, same caller: one distinct code"
      assert_equal 2, Rails.cache.read("retest:#{s.id}:code:#{s.respondent_code_digest("sam14")}")
    end
  end
end
