require "test_helper"

# The server half of the mobile background: a phone-only backdrop on the three
# types whose answer takes the whole screen, surviving an editor autosave on a
# card that is ALSO carrying a desktop picture.
#
# That combination is the whole feature and it used to be the one thing the
# sanitiser refused. "A backdrop shows wherever the panel is not already
# covered by an opaque medium" is a statement about the DESKTOP panel: on a
# phone these three draw no picture at all, so their backdrop is not behind
# anything — it is the only design the phone can carry, and refusing to store
# it left a creator unable to design the phone view of exactly the cards that
# are only ever full-screen.
#
# mobile_background_test.rb drives the browser for where it may paint;
# range_card_backdrop_test covers the older half of the same rule.
class MobileBackgroundSaveTest < ActionDispatch::IntegrationTest
  HERO = "/assets/verto-library/left-panel/sports-people-desktop-2.jpg".freeze
  BG   = "/assets/verto-library/mobile-backgrounds/sports-people-mobile-3.jpg".freeze

  def setup
    @user = User.create!(name: "U", email_address: "mbg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "mbg-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Football", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "w", "text" => "Kick off" },
        { "type" => "tap_card", "cid" => "t1", "text" => "Your call?",
          "options" => [ "Ticket prices", "Kick-off times" ], "image" => HERO },
        { "type" => "nps", "cid" => "n1", "text" => "How likely?", "image" => HERO },
        { "type" => "prioritise", "cid" => "p1", "text" => "In order?",
          "options" => [ "Cheaper", "Closer" ], "image" => HERO },
        { "type" => "open_ended", "cid" => "o1", "text" => "More?", "image" => HERO }
      ]
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def patch_cards(cards)
    patch survey_path(@survey), params: { cards: cards }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  # Every card in the deck gains the same backdrop; which of them KEEP it is
  # the rule under test.
  def patch_all_with_background
    patch_cards(@survey.cards.map { |c| c["cid"] == "w" ? c : c.merge("media_bg" => { "image" => BG }) })
    assert_response :success
    @survey.reload.cards.index_by { |c| c["cid"] }
  end

  test "the three full-screen types keep a mobile background alongside their picture" do
    cards = patch_all_with_background

    %w[t1 n1 p1].each do |cid|
      assert_equal BG, cards[cid].dig("media_bg", "image"),
                   "#{cid} lost its mobile background. The phone draws this type no picture at " \
                   "all, so there is nothing for the backdrop to be hidden behind."
      assert_equal HERO, cards[cid]["image"],
                   "#{cid}'s own picture was dropped for the backdrop — they are separate " \
                   "designs for separate screens and both have to survive"
    end
  end

  test "an ordinary card carrying a picture still refuses one" do
    cards = patch_all_with_background

    assert_nil cards["o1"]["media_bg"],
               "a backdrop was stored behind a photo the phone DOES draw as a hero, where it " \
               "is a control that changes nothing. This change narrows that rule to the three " \
               "full-screen types; it does not remove it."
  end

  test "the backdrop survives the autosave that just re-sends the deck" do
    patch_all_with_background

    # What the editor posts on the next keystroke: the same deck, rebuilt from
    # the DOM. The round trip is where a backdrop with no home gets lost.
    patch_cards(@survey.reload.cards)
    assert_response :success

    assert_equal BG, @survey.reload.cards.find { |c| c["cid"] == "t1" }.dig("media_bg", "image")
  end

  test "a colour is a background too, and needs no picture behind it" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[1].merge("media_bg" => { "color" => "#2e3564" }) ])
    assert_response :success

    assert_equal({ "color" => "#2e3564" },
                 @survey.reload.cards.find { |c| c["cid"] == "t1" }["media_bg"])
  end

  test "a backdrop the server refuses is still reported rather than dropped in silence" do
    patch_cards([ @survey.cards[0],
                  @survey.cards[1].merge("media_bg" => { "image" => "https://evil.example/x.png" }) ])
    assert_response :success

    body = JSON.parse(response.body)
    assert_includes body["warnings"], "media_bg",
                    "the editor's 'an image didn't stick' pill is driven off this, and a " \
                    "newly-allowed type must not be a newly-silent one"
    assert_equal "t1", body["warning_details"].find { |d| d["code"] == "media_bg" }["cid"]
  end
end
