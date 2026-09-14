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

  # What the app logged during the block. Rails.logger is a BroadcastLogger, so
  # a second sink can be hung on it without replacing what the suite already
  # writes to.
  def capture_log
    io  = StringIO.new
    tap = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(tap)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(tap) if tap
  end

  test "flags a warning and does not silently succeed when an oversized image is dropped" do
    patch_cards([ { type: "multiple_choice", text: "Q", image: OVERSIZED } ])

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_includes body["warnings"], "image"

    assert_nil @survey.reload.cards.first["image"]
  end

  # The codes say something in the deck was dropped; `warning_details` says
  # WHICH card, so the editor can name it. A creator who had just uploaded a
  # picture that saved fine was told "an image didn't stick": the drop was
  # another card's older image, and neither the pill nor the log could say so.
  test "warning_details names the card that lost its image, and the log records the drop" do
    log = capture_log do
      patch_cards([
        { cid: "c_fine", type: "multiple_choice", text: "Q1", image: PEXELS_URL },
        { cid: "c_lost", type: "multiple_choice", text: "Q2", image: OVERSIZED }
      ])
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ "image" ], body["warnings"]

    assert_equal 1, body["warning_details"].size
    detail = body["warning_details"].first
    assert_equal "image",  detail["code"]
    assert_equal "c_lost", detail["cid"]
    assert_equal "image/png data URL, #{OVERSIZED.bytesize} bytes", detail["value"],
                 "the shape of the rejected value travels; the value itself never does"

    # Only the drop lines: the request log above them echoes the whole payload.
    drops = log.lines.grep(/\[SurveysController#update\] survey/)
    assert_equal 1, drops.size, "one line per drop, and a card that kept its image is not a drop"
    assert_match(/survey #{@survey.id} card c_lost: dropped image — image\/png data URL, #{OVERSIZED.bytesize} bytes/,
                 drops.first)

    cards = @survey.reload.cards
    assert_equal PEXELS_URL, cards[0]["image"]
    assert_nil cards[1]["image"]
  end

  test "a dropped tap-card statement image carries the slot it was in" do
    patch_cards([ { cid: "c_tap", type: "tap_card", text: "Swipe", options: [ "A", "B" ],
                    option_images: [ PEXELS_URL, OVERSIZED ] } ])

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ "option_images" ], body["warnings"]
    assert_equal [ { "code" => "option_images", "cid" => "c_tap", "index" => 1 } ],
                 body["warning_details"].map { |d| d.except("value") }
  end

  test "returns an empty warnings array when nothing is dropped" do
    patch_cards([ { type: "multiple_choice", text: "Q", image: PEXELS_URL } ])

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_equal [], body["warnings"]
    assert_equal [], body["warning_details"]
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
