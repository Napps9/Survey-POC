require "test_helper"

class BirthDatePickerTest < ActionDispatch::IntegrationTest
  def published_survey(cards)
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: cards,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "an open_ended card with input: month renders two numeric month/year fields" do
    s = published_survey([
      { "type" => "welcome_card", "title" => "hi" },
      { "type" => "open_ended", "input" => "month", "text" => "When were you born?",
        "demographic" => true }
    ])

    get play_survey_path(s.publish_token)
    assert_response :success
    # Plain numeric fields, not a native <input type="month"> — that control's
    # inline segments are browser/OS-rendered and can spell the month out in
    # English (e.g. "May"), which isn't universal across the app's locales.
    assert_select "input.freeform-month[placeholder='02']"
    assert_select "input.freeform-year[placeholder='1995']"
    assert_select "input[type='month']", false
    assert_select "textarea.freeform-textarea", false
    assert_select ".freeform-date-hint", text: "MM / YYYY"
  end

  test "an open_ended card with input: date still renders the full date picker (unrelated to birth date)" do
    s = published_survey([
      { "type" => "welcome_card", "title" => "hi" },
      { "type" => "open_ended", "input" => "date", "text" => "When did you last visit?" }
    ])

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "input.freeform-date[type='date']"
  end

  test "an open_ended card with no input flavour still renders free text" do
    s = published_survey([
      { "type" => "welcome_card", "title" => "hi" },
      { "type" => "open_ended", "text" => "Tell us more" }
    ])

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "textarea.freeform-textarea"
    assert_select "input.freeform-date", false
  end
end
