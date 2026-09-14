require "test_helper"

# The backdrop behind a range card's reaction animation (card["media_bg"]), all
# the way through an editor autosave: "the background image I add to a range
# question, that sits behind the animated assets, doesn't save. I have to re-add
# every time I load the editor."
#
# The rule is "a backdrop shows wherever the panel is not already covered by an
# opaque medium", and a range card's panel is its reaction set — so a range card
# keeps its backdrop whatever else it is carrying. That rule is stated in four
# places (ApplicationHelper#card_takes_backdrop?, Survey.sanitize_cards_images!,
# media_picker#_cardTakesBackground, survey-editor#serialize) and the serialiser
# was the one that had it wrong: it dropped media_bg for any card holding an
# `image`, with no range exception. A range card switched over from a photo card
# still holds one — the panel stops drawing it, nothing clears it — so the
# backdrop was omitted from every autosave, silently, because nothing was
# dropped server-side to warn about.
#
# This covers the server half of that path (the payload the fixed serialiser
# sends, arriving and persisting); range_card_background_test drives the
# browser for the half that reads the DOM.
class RangeCardBackdropTest < ActionDispatch::IntegrationTest
  ASSET  = "/assets/verto-library/backgrounds/nature.jpg".freeze
  PEXELS = "https://images.pexels.com/photos/9/pexels-photo-9.jpeg?auto=compress&cs=tinysrgb&w=1200".freeze

  def setup
    @user = User.create!(name: "U", email_address: "bg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "bg-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Football", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "w", "text" => "Kick off" },
        # The reported state: a range card that still carries the photo it had
        # before someone switched its type.
        { "type" => "range", "cid" => "r1", "text" => "Would you use it?",
          "options" => [ "Wouldn't matter", "Not for me", "I might", "Probably", "Definitely" ],
          "image" => ASSET }
      ]
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def patch_cards(cards)
    patch survey_path(@survey), params: { cards: cards }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def range_card(extra = {})
    @survey.cards[1].merge(extra)
  end

  test "a backdrop on a range card that is still carrying an image survives the save" do
    patch_cards([ @survey.cards[0],
                  range_card("media_bg" => { "color" => "#2e3564", "image" => PEXELS }) ])
    assert_response :success

    stored = @survey.reload.cards[1]["media_bg"]
    assert_equal "#2e3564", stored["color"]
    assert_equal PEXELS, stored["image"],
                 "the card's own photo is not drawn on a range panel, so it never " \
                 "disqualified the backdrop behind the animation"
  end

  test "the backdrop is still there after a second autosave that says nothing new" do
    patch_cards([ @survey.cards[0], range_card("media_bg" => { "image" => PEXELS }) ])
    assert_response :success

    # The payload the editor sends on every subsequent keystroke: the same deck,
    # rebuilt from the DOM. This is the round trip that used to lose it.
    patch_cards(@survey.reload.cards)
    assert_response :success
    assert_equal PEXELS, @survey.reload.cards[1].dig("media_bg", "image")
  end

  test "a backdrop the server refuses is reported rather than dropped in silence" do
    patch_cards([ @survey.cards[0],
                  range_card("media_bg" => { "color" => "#2e3564", "image" => "https://evil.example/x.png" }) ])
    assert_response :success

    body = JSON.parse(response.body)
    assert_includes body["warnings"], "media_bg",
                    "the editor's 'an image didn't stick' pill is driven off this"
    detail = body["warning_details"].find { |d| d["code"] == "media_bg" }
    assert_equal "r1", detail["cid"], "the pill has to be able to name the card"

    assert_equal({ "color" => "#2e3564" }, @survey.reload.cards[1]["media_bg"],
                 "the colour it could validate stays; only the picture was refused")
  end

  test "a photo card's backdrop is still dropped, and that is not a regression" do
    patch_cards([ @survey.cards[0].merge("image" => ASSET, "media_bg" => { "color" => "#2e3564" }),
                  @survey.cards[1] ])
    assert_response :success

    refute @survey.reload.cards[0].key?("media_bg"),
           "a photo covers the panel edge to edge — there is nothing to see behind it"
  end
end
