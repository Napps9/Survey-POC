require "test_helper"

class SurveysUpdateTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "su-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "su-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(
      title: "S", theme: "Space", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: []
    )
  end

  OVERSIZED  = "data:image/png;base64,#{"A" * 3_000_001}"
  PEXELS_URL = "https://images.pexels.com/photos/123/pexels-photo-123.jpeg?auto=compress&cs=tinysrgb&w=1200&h=627&fit=crop"

  def patch_cards(cards)
    patch survey_path(@survey), params: { cards: cards }.to_json,
          headers: { "Content-Type" => "application/json" }
  end

  test "flags a warning and does not silently succeed when an oversized image is dropped" do
    patch_cards([ { type: "multiple_choice", text: "Q", image: OVERSIZED } ])

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_includes body["warnings"], "image"

    assert_nil @survey.reload.cards.first["image"]
  end

  test "returns an empty warnings array when nothing is dropped" do
    patch_cards([ { type: "multiple_choice", text: "Q", image: PEXELS_URL } ])

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_equal [], body["warnings"]
    assert_equal PEXELS_URL, @survey.reload.cards.first["image"]
  end

  test "option_images survive a save even while the card's current type isn't tap_card" do
    # Regression test: the client used to only serialize option_images while
    # the card's CURRENT type was tap_card, so switching a card away from
    # tap_card and autosaving silently deleted its saved statement images
    # (sanitize_cards_images! itself has no such type gate, unlike
    # pages/range_theme, so the server-side half of this was always safe).
    patch_cards([ { type: "range", text: "Q", options: [ "A", "B" ], option_images: [ PEXELS_URL, PEXELS_URL ] } ])

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_equal [], body["warnings"]
    assert_equal [ PEXELS_URL, PEXELS_URL ], @survey.reload.cards.first["option_images"]
  end
end
