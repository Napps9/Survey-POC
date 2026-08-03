require "test_helper"

# The editor page ships a keyword→URL icon map (#option-icon-map) so markup
# built client-side (type switches, newly added options) can render the same
# per-option icons the server inlines. Without it, switching a card's answer
# type silently stripped every icon until the next full reload.
class EditorOptionIconMapTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Icons", slug: "icons-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "icons-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  test "the editor page emits the option-icon map with usable URLs" do
    survey = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] } ]
    )

    get survey_path(survey)

    assert_response :success
    assert_select "script#option-icon-map", 1
    map = JSON.parse(css_select("script#option-icon-map").first.text)
    assert_operator map["keywords"].size, :>=, 40, "the keyword lookup lost its entries"
    assert_operator map["ids"].size, :>=, 40, "the id lookup lost its entries"
    assert(map["keywords"].values.all? { |url| url.include?("option-icons") && url.end_with?(".svg") },
           "keyword values must be fetchable SVG asset URLs")
  end
end
