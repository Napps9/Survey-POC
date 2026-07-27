require "test_helper"

# The AI streaming endpoints keep their incremental reveal — but bounded, so a
# handful of people watching reports write themselves can't consume every Puma
# thread and take the instance down for pages that never touch Claude.
class StreamConcurrencyTest < ActionDispatch::IntegrationTest
  POOL = LimitsConcurrentStreams::POOL

  def setup
    @org  = Organisation.create!(name: "O", slug: "sc-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "sc-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ],
      results_summary: "Cached insights.", results_summary_response_count: 0
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def teardown
    # Never let a test leak a slot into the next one.
    POOL.release while POOL.available < LimitsConcurrentStreams.slot_count
  end

  def fill_pool
    LimitsConcurrentStreams.slot_count.times { assert POOL.acquire }
  end

  test "at least two threads are always reserved for ordinary requests" do
    # The whole point: the cap has to be strictly below the thread count, or it
    # isn't a cap at all.
    threads = Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
    assert_operator LimitsConcurrentStreams.slot_count, :<, threads
    assert_operator LimitsConcurrentStreams.slot_count, :>=, 1
  end

  test "a stream runs normally while a slot is free" do
    get survey_results_summary_path(@survey)
    assert_response :success
    assert_equal "Cached insights.", response.body
  end

  test "a stream is turned away with a reason once the slots are taken" do
    fill_pool

    get survey_results_summary_path(@survey)
    assert_response :service_unavailable
    assert_match(/try again in a moment/i, response.body)
  end

  test "the report stream and the chat share the same budget" do
    fill_pool

    get survey_results_report_stream_path(@survey)
    assert_response :service_unavailable

    post survey_chat_path(@survey), params: { messages: [] }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :service_unavailable
  end

  test "ordinary pages stay served while every stream slot is taken" do
    # This is the outcome the whole change exists for: the dashboard and the
    # results page must not care that the streams are saturated.
    fill_pool

    get root_path
    assert_response :success

    get survey_path(@survey)
    assert_response :success
  end

  test "a slot is returned after the stream finishes" do
    before = POOL.available
    get survey_results_summary_path(@survey)
    assert_response :success
    assert_equal before, POOL.available, "the around_action must release the slot"
  end

  test "a slot is returned even when the action blows up mid-stream" do
    # The leak case, and the reason this is an around_action rather than a guard:
    # a permanently shrinking pool would be a worse bug than the one it fixes.
    before = POOL.available
    stub_method(ResultsSummariser, :new, ->(*) { raise "boom" }) do
      @survey.update_columns(results_summary: nil, results_summary_response_count: nil)
      get survey_results_summary_path(@survey)
    end
    assert_equal before, POOL.available
  end

  test "a turned-away caller does not consume a slot" do
    fill_pool
    taken = POOL.available

    get survey_results_summary_path(@survey)
    assert_response :service_unavailable
    assert_equal taken, POOL.available, "a rejected request must not release someone else's slot"
  end

  test "the pool hands out exactly its size and no more" do
    pool = LimitsConcurrentStreams::SlotPool.new(2)
    assert pool.acquire
    assert pool.acquire
    assert_not pool.acquire, "third caller must be turned away"

    pool.release
    assert pool.acquire, "a released slot is reusable"
  end

  test "releasing more than was taken cannot inflate the pool" do
    pool = LimitsConcurrentStreams::SlotPool.new(1)
    5.times { pool.release }
    assert_equal 1, pool.available
    assert pool.acquire
    assert_not pool.acquire
  end
end
