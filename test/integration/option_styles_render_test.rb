require "test_helper"

# Styled options must render their overrides in the player (the point of the
# feature) and carry the editor affordances (style button + data attributes)
# only in the editor.
class OptionStylesRenderTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Styled", slug: "styled-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "st-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[Alpha Beta Gamma],
                 "option_styles" => [ { "color" => "#aabbcc" }, { "emoji" => "🎯" }, { "icon" => "basketball" } ] } ]
    )
    @survey.update!(publish_token: SecureRandom.hex(8))
  end

  test "the player renders colour, emoji and explicit icon overrides" do
    get play_survey_path(@survey.publish_token)

    assert_response :success
    assert_match "linear-gradient(135deg, #{BrandPalette.lighten("#aabbcc", 0.18)}, #aabbcc)", response.body,
                 "the picked hex must paint the tile (with the lightened gradient stop)"
    assert_select ".choice-icon-emoji", text: "🎯"
    # Explicit icon: the basketball SVG inlined into the third tile.
    assert_select ".choice-list-tile svg.choice-icon-svg", { minimum: 1 }
    # No editor chrome for respondents.
    assert_select ".option-style-btn", 0
    assert_select "[data-option-color]", 0
  end

  test "the editor carries the style button, data attrs and the popover" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    @survey.update!(publish_token: nil) # unlock editing

    get survey_path(@survey)

    assert_response :success
    assert_select ".option-style-btn", { minimum: 3 }
    assert_select "[data-option-color='#aabbcc']", 1
    assert_select "[data-option-emoji='🎯']", 1
    assert_select "[data-option-icon='basketball']", 1
    assert_select "[data-option-style-target=popover]", 1
    assert_match "data-card-option-styles", response.body,
                 "the type panel's rebuild snapshot must include the styles"
  end

  test "the autosave round trip preserves sanitised styles and drops junk" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    @survey.update!(publish_token: nil)

    patch survey_path(@survey),
          params: { cards: [ { "type" => "multiple_choice", "cid" => @survey.cards.first["cid"],
                               "text" => "Pick", "options" => %w[Alpha Beta],
                               "option_styles" => [ { "color" => "#123456", "emoji" => "⭐" }, { "icon" => "not-real" } ] } ] }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :success
    styles = @survey.reload.cards.first["option_styles"]
    assert_equal({ "color" => "#123456", "emoji" => "⭐" }, styles[0])
    assert_nil styles[1], "an invalid icon id leaves nothing valid behind"
  end
end
