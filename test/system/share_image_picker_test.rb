require "application_system_test_case"

# The share card's preview picture, driven through the editor.
#
# Until this panel existed the picture was the one part of the unfurl a creator
# could look at and not change: Survey#share_image_path walked gate image →
# backdrop → first card → library and the editor drew whatever fell out. Fine
# as a guarantee (there is always a picture), poor as a decision — the only
# thing a stranger sees before they have read a word went to whichever card
# happened to come first.
#
# A browser is the only place this can be tested. The tiles are not rendered
# with the page: they are gathered from the live cards feed when the panel
# opens, because the media picker repaints a card and writes the new URL onto
# its data-card-image with no reload, and a list baked in at render time would
# be missing exactly the picture the creator had just added. So what is under
# test is the DOM read, not a server-rendered list.
class ShareImagePickerTest < ApplicationSystemTestCase
  CARD_ONE_IMAGE = "https://images.pexels.com/photos/101/one.jpg".freeze
  CARD_TWO_IMAGE = "https://images.pexels.com/photos/202/two.jpg".freeze
  BACKDROP       = "https://images.pexels.com/photos/303/backdrop.jpg".freeze

  CARDS = [
    { "type" => "welcome_card", "cid" => "w1", "title" => "Hello" },
    { "type" => "yes_no", "cid" => "q1", "text" => "Do you play?", "options" => %w[Yes No],
      "image" => CARD_ONE_IMAGE },
    { "type" => "yes_no", "cid" => "q2", "text" => "Would you again?", "options" => %w[Yes No],
      "media_bg" => { "image" => CARD_TWO_IMAGE } }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "sip-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Sip", email_address: "sip-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Share", theme: "Sports", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS, background_image: BACKDROP,
                                   # Any share copy opens the card, which is where the
                                   # thumbnail (and so the picker's trigger) lives.
                                   share_title: "Written")
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Do you play?"
  end

  def open_picker
    find("button.unfurl-thumb-btn").click
    assert_selector ".share-image-picker", visible: true
  end

  def thumb_src = find("img.unfurl-thumb")[:src]

  def tile_urls
    all(".share-image-tile", visible: true).map { |t| t[:"data-url"] }
  end

  # Every picture the Verto carries, and no picture it does not. The backdrop
  # and the gate image are in here as well as the card images: both are steps
  # in the derivation this panel overrides, so leaving them out would make
  # choosing deliberately a way to LOSE options.
  test "the panel offers every picture the Verto carries, plus Automatic" do
    open_editor
    open_picker

    urls = tile_urls
    assert_equal "", urls.first, "Automatic is always first — it is how a pick is undone"
    assert_includes urls, CARD_ONE_IMAGE
    assert_includes urls, CARD_TWO_IMAGE, "a card's animation backdrop is a card image too"
    assert_includes urls, BACKDROP
    assert_equal urls.uniq, urls, "the same photograph on three cards is one choice, not three"
  end

  test "the tiles are labelled by the card they came from" do
    open_editor
    open_picker

    assert_selector ".share-image-tile[data-url='#{CARD_ONE_IMAGE}'] .share-image-tile-label",
                    text: "Card 2"
    assert_selector ".share-image-tile[data-url='#{BACKDROP}'] .share-image-tile-label",
                    text: "Background"
  end

  # The whole point: the picked picture is stored, and it is what og:image will
  # emit. Read back off the record rather than off the panel, because the panel
  # would happily show a pick that never reached the server.
  test "picking a card image stores it and repaints the thumbnail" do
    open_editor
    before = thumb_src
    open_picker

    find(".share-image-tile[data-url='#{CARD_TWO_IMAGE}']").click

    assert_no_selector ".share-image-picker", visible: true
    assert_equal CARD_TWO_IMAGE, thumb_src
    refute_equal before, thumb_src
    assert wait_until { @survey.reload.share_image == CARD_TWO_IMAGE },
           "the pick has to reach the column — the unfurl is rendered from it, not from the panel"
    assert_equal CARD_TWO_IMAGE, @survey.reload.share_image_path
  end

  # "Let it pick" has to be reachable again afterwards, or the first pick is a
  # one-way door. Automatic clears the column rather than storing a URL, so the
  # link goes back to being chosen for — and the derivation is untouched
  # underneath, which is what makes that possible.
  test "Automatic clears the pick and puts the derivation back" do
    @survey.update!(share_image: CARD_TWO_IMAGE)
    open_editor
    assert_equal CARD_TWO_IMAGE, thumb_src

    open_picker
    # The current pick is marked, so the creator can see which one is in force.
    assert_selector ".share-image-tile.is-picked[data-url='#{CARD_TWO_IMAGE}'][aria-pressed='true']"

    find(".share-image-tile[data-url='']").click
    assert wait_until { @survey.reload.share_image.nil? }
    assert_equal @survey.reload.default_share_image_path, @survey.share_image_path
    assert_equal @survey.default_share_image_path, thumb_src
  end

  # The list is read from the feed at open time, not rendered with the page.
  # This is the property that makes that worth the trouble: a picture added to
  # a card a moment ago is in the panel without a reload.
  test "a picture added to a card since page load is offered" do
    open_editor
    fresh = "https://images.pexels.com/photos/404/fresh.jpg"
    execute_script(<<~JS)
      document.querySelector("[data-card-cid='w1']").dataset.cardImage = "#{fresh}"
    JS

    open_picker
    assert_includes tile_urls, fresh
  end

  # Escape and an outside click both close it, and neither leaves a listener
  # behind that closes the next thing the creator opens.
  test "the panel closes on Escape and on a click outside it" do
    open_editor

    open_picker
    # press_keys, not Element#send_keys: send_keys clicks the node's centre
    # first, and on this panel that click IS the outside-click dismissal — the
    # test would pass without Escape ever being handled.
    press_keys(:escape)
    assert_no_selector ".share-image-picker", visible: true

    open_picker
    find(".gate-share-hint").click
    assert_no_selector ".share-image-picker", visible: true
  end

  # Removing the card removes the override with it. Leaving share_image set
  # would keep a picked picture on a link whose card the creator has just taken
  # off — and share_copy? counts the column, so the card would reopen on the
  # next load as though the removal had not happened.
  test "removing the share card drops the picked picture too" do
    @survey.update!(share_image: CARD_TWO_IMAGE)
    open_editor

    find("[data-gate-cards-target='shareCard'] .card-delete-btn").click
    assert wait_until { @survey.reload.share_image.nil? }
    refute_predicate @survey.reload, :share_copy?
  end
end
