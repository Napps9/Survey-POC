require "test_helper"

class SurveyGeneratorWelcomeTest < ActiveSupport::TestCase
  def gen = SurveyGenerator.allocate # skip API-key init; we only call the helper

  test "prepends a welcome card built from the brief when the model omits one" do
    payload = {
      "title" => "Members insights", "theme" => "Membership", "description" => "A quick check-in",
      "cards" => [ { "type" => "tap_card", "text" => "Q1", "options" => %w[neg neut pos] } ]
    }

    gen.send(:ensure_welcome_card!, payload)

    assert_equal "welcome_card", payload["cards"].first["type"]
    assert_equal "Members insights", payload["cards"].first["title"]
    assert_equal "A quick check-in", payload["cards"].first["text"]
    assert_equal 2, payload["cards"].size
  end

  test "leaves an existing welcome card untouched" do
    payload = { "cards" => [
      { "type" => "welcome_card", "title" => "Hi" },
      { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] }
    ] }

    gen.send(:ensure_welcome_card!, payload)

    assert_equal 2, payload["cards"].size
    assert_equal "Hi", payload["cards"].first["title"]
  end

  test "falls back to the theme, then a default, for the welcome title" do
    p1 = { "theme" => "Climate", "cards" => [] }
    gen.send(:ensure_welcome_card!, p1)
    assert_equal "Climate", p1["cards"].first["title"]

    p2 = { "cards" => [] }
    gen.send(:ensure_welcome_card!, p2)
    assert_equal "Welcome", p2["cards"].first["title"]
  end
end
