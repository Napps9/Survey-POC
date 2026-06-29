require "test_helper"

class ResponseTest < ActiveSupport::TestCase
  def setup
    @org    = Organisation.create!(name: "O", slug: "resp-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "yes_no", "text" => "Like it?", "options" => %w[Yes No] } ])
  end

  def build(answers, status: "started")
    @survey.responses.create!(session_token: SecureRandom.uuid, status: status, answers: answers)
  end

  test "answered flag is true when any card has a value" do
    r = build({ "1" => { "value" => "Yes" } })
    assert r.answered, "a real answer should mark the response answered"
  end

  test "answered flag is false with no value present" do
    assert_not build({}).answered
    assert_not build({ "1" => { "value" => "" } }).answered, "blank value is not an answer"
    assert_not build({ "1" => { "other" => "" } }).answered
  end

  test "answered flag is kept in sync on update" do
    r = build({})
    assert_not r.answered
    r.update!(answers: { "1" => { "value" => "No" } })
    assert r.answered
  end

  # ── Survey responder counts (driven by the flag, in SQL) ──

  test "responders_count counts only responses that answered" do
    build({ "1" => { "value" => "Yes" } }, status: "completed")
    build({ "1" => { "value" => "No" } },  status: "started")
    build({})                                # not a responder
    assert_equal 2, @survey.responders_count
  end

  test "completion_rate is the share of responders who completed" do
    build({ "1" => { "value" => "Yes" } }, status: "completed")
    build({ "1" => { "value" => "No" } },  status: "completed")
    build({ "1" => { "value" => "Yes" } }, status: "started")
    assert_equal 67, @survey.completion_rate # 2 of 3 responders completed
  end

  test "completion_rate is nil with no responders" do
    build({})
    assert_nil @survey.completion_rate
  end
end
