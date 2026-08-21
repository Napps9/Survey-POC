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

  # The library is 48 sport SVGs and nothing else, so on a card about cost or
  # safety the grid is a wall of things that mean nothing. Naming its scope is
  # the difference between "this library stops at sport" and "this picker is
  # broken" — which is how it actually got reported.
  test "the style popover names the icon library's scope and points at the emoji" do
    survey = @org.surveys.create!(
      title: "S", theme: "Cost of living", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => [ "Cheaper sessions" ] } ]
    )

    get survey_path(survey)
    assert_response :success

    assert_select ".option-style-row--icons span", text: "Sport icons"
    assert_select ".option-style-icon-note", 1 do |note|
      assert_match(/only covers sport/i, note.first.text)
      assert_match(/emoji/i, note.first.text, "and sends them to the control that does cover it")
    end
  end

  # The premise of that note: nothing in this library matches ordinary option
  # copy, so a creator on a non-sport Verto has no useful pick to make. If a
  # general icon set ever lands, this is the test that should start failing.
  test "the icon library matches nothing on ordinary non-sport option labels" do
    labels = [ "Cheaper sessions", "Better facilities", "Closer to home",
               "Cost of living", "Mental health", "Street lighting" ]
    labels.each do |label|
      assert_nil OptionIconLibrary.svg_for(label),
        "#{label.inspect} unexpectedly matched an icon — retire the scope note if the library grew"
    end
  end
end
