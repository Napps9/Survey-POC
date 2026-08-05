require "test_helper"

# The point of promoting a label emoji into option_styles is that it then
# renders INSIDE the option's icon tile — the box — with the label reading as
# plain words. This asserts that end state on the surfaces creators and
# respondents actually look at.
class OptionLabelEmojiRenderTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Emoji", slug: "emr-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "E", email_address: "emr-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Emoji", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "cid" => "c1", "text" => "List?",
          "options" => [ "🎯 Pay off debt", "Start saving" ] },
        { "type" => "select_one_grid", "cid" => "c2", "text" => "Grid?",
          "options" => [ "🔥 Very unsafe", "A bit unsafe" ] }
      ]
    )
  end

  test "the emoji renders in the tile and the label reads as plain words" do
    @survey.update!(publish_token: SecureRandom.hex(8))
    get play_survey_path(@survey.publish_token)
    assert_response :success

    # List type: emoji inside .choice-list-tile, not in the label span.
    assert_select ".choice-list-tile .choice-icon-emoji", text: "🎯"
    assert_select ".choice-list-label", text: "Pay off debt"
    # Grid type: emoji inside .choice-card-bg.
    assert_select ".choice-card-bg .choice-icon-emoji", text: "🔥"
    assert_select ".choice-label", text: "Very unsafe"

    refute_match(/choice-list-label[^>]*>\s*🎯/, response.body,
                 "the emoji must not still be sitting beside the words")
  end

  test "the editor shows the same, with the emoji on the style popover's data" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    get survey_path(@survey)
    assert_response :success

    assert_select ".choice-list-tile .choice-icon-emoji", text: "🎯"
    assert_select ".choice-list-label", text: "Pay off debt"
    # The 🎨 popover reads its state off these, so the emoji is now editable
    # and clearable like any other option icon.
    assert_select "[data-option-emoji='🎯']", 1
  end

  test "a label emoji beats the keyword icon that would otherwise fill the tile" do
    # Write the cards as a draft, THEN publish — the hoist deliberately skips a
    # published Verto, so doing both in one save would (correctly) skip it.
    @survey.update!(cards: [ { "type" => "multiple_choice", "cid" => "c1", "text" => "Q",
                               "options" => [ "🎯 Basketball" ] } ])
    @survey.update!(publish_token: SecureRandom.hex(8))
    get play_survey_path(@survey.publish_token)

    assert_response :success
    assert_select ".choice-list-tile .choice-icon-emoji", text: "🎯"
    assert_select ".choice-list-tile svg.choice-icon-svg", 0,
                  "the creator's own emoji wins the tile over a keyword match"
  end
end
