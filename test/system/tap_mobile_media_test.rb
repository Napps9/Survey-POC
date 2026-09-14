require "application_system_test_case"

# "On mobile, on the tap card Q, when you click Change media, it does actually
# upload — but to the left hand side on desktop 😂 so the current change media
# button is not mobile specific, it replaces the main desktop asset and not the
# mobile background. The platform is uploading the background, just putting it
# in the wrong place."
#
# A tap card's hero panel is DESKTOP furniture. The stack already carries a
# picture per statement, so a card-level hero behind it read as torn/double
# imagery and the phone drops the strip entirely — .split-left becomes
# `display: contents` (see "Tap card on mobile" in application.css, and the
# editor's own phone/tablet bezel, which drops it the same way). The panel's
# pills float on regardless, because they are absolutely positioned against the
# card rather than the panel — and they still pointed at the hero. So on a
# phone "Change media" changed a picture that phone never shows.
#
# What is asserted is WHERE THE PICTURE LANDS, not which handler ran: the
# report is about a stored image ending up in the wrong slot, and that is a
# thing the dataset the serialiser reads can be asked about directly.
class TapMobileMediaTest < ApplicationSystemTestCase
  PHONE   = [ 390, 844 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  HERO       = "https://images.pexels.com/photos/900/hero.jpg".freeze
  STATEMENTS = [ "Tickets supporters can't afford", "Kick-off times for TV" ].freeze
  # Only the FIRST statement carries a picture: the second is what proves
  # Reposition follows the pager rather than the card.
  OPTION_IMAGES = [ "https://images.pexels.com/photos/901/one.jpg", "" ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tm-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tm", email_address: "tm-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Tap", theme: "football", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "What is your call?",
          "options" => STATEMENTS.dup, "option_images" => OPTION_IMAGES.dup,
          "image" => HERO }
      ]
    )
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_editor(width: DESKTOP[0], height: DESKTOP[1])
    page.driver.browser.resize(width: width, height: height)
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='t1'] .rotate-card", minimum: 2
  end

  # The editor's phone bezel: the same editable DOM, reframed to the layout a
  # respondent gets — which is where the hero strip goes away.
  def switch_to_phone_frame
    find(".device-toggle-btn[data-device='mobile']").click
    assert_selector ".device-mobile", wait: 5
    assert_equal "contents", panel_display,
                 "the phone frame is still drawing the tap card a hero strip — " \
                 "the player gives it none, so this preview is wrong before the pills are"
  end

  def panel_display
    evaluate_script(
      %(getComputedStyle(document.querySelector("[data-card-cid='t1'] .split-left")).display)
    )
  end

  def card_data(key)
    evaluate_script(%(document.querySelector("[data-card-cid='t1']").dataset.#{key} || ""))
  end

  def option_images
    JSON.parse(card_data("cardOptionImages").presence || "[]")
  end

  def mounted_pos_image
    evaluate_script(
      %(document.querySelector("[data-media-picker-target='posImg']").style.backgroundImage)
    )
  end

  # The shortest real path from a pill to a stored picture: pick the first
  # Verto Library tile and apply it. Returns the URL that was picked.
  def apply_first_library_image
    tile = all("[data-media-picker-target='libraryItem']").find { |t| t[:"data-url"].present? }
    assert tile, "the Verto Library rendered no pickable tile"
    url = tile[:"data-url"]
    tile.click
    assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
    find("[data-media-picker-target='applyBtn']").click
    assert_no_selector ".media-modal-backdrop", visible: true
    url
  end

  # The floating pills share the bottom of a phone-width editor with the
  # studio's own dock, so the click is dispatched rather than aimed — what is
  # under test is which slot the handler fills, not what is on top of what.
  def click_panel_pill(selector)
    ok = evaluate_script(<<~JS)
      (() => {
        const pill = document.querySelector("[data-card-cid='t1'] #{selector}")
        if (!pill || pill.hidden) return false
        pill.click()
        return true
      })()
    JS
    assert ok, "no #{selector} on the tap card's panel"
  end

  # ── Change media ────────────────────────────────────────────────────────

  test "in the phone frame Change media fills the statement on screen, not the desktop hero" do
    open_editor
    hero = card_data("cardImage")
    switch_to_phone_frame

    within("[data-card-cid='t1']") { find(".add-media-fab").click }
    picked = apply_first_library_image

    assert_equal picked, option_images[0],
                 "the picture went somewhere other than the statement the phone is showing"
    assert_equal hero, card_data("cardImage"),
                 "the phone's pill rewrote the card's DESKTOP hero — the whole of the report"
  end

  test "on a desktop the same pill still fills the card's own hero panel" do
    open_editor

    within("[data-card-cid='t1']") { find(".add-media-fab").click }
    picked = apply_first_library_image

    assert_equal picked, card_data("cardImage"),
                 "the panel a desktop creator is looking at is the one the pill fills"
    assert_equal OPTION_IMAGES, option_images,
                 "a desktop pick reached into the statements it has nothing to do with"
  end

  test "at phone width the studio's pill fills the statement too" do
    open_editor(width: PHONE[0], height: PHONE[1])
    assert_selector ".m-studio-on"
    assert_equal "contents", panel_display
    hero = card_data("cardImage")

    click_panel_pill(".add-media-fab")
    picked = apply_first_library_image

    assert_equal picked, option_images[0]
    assert_equal hero, card_data("cardImage")
  end

  # ── Reposition ──────────────────────────────────────────────────────────

  test "in the phone frame Reposition reframes the statement, and follows the pager" do
    open_editor
    statement_image = option_images[0]
    switch_to_phone_frame

    within("[data-card-cid='t1']") { find(".media-adjust-fab").click }
    assert_selector "[data-media-picker-target='posStage']", visible: true
    assert_includes mounted_pos_image, statement_image,
                    "the stage opened on the hero the phone never shows"
    find(".media-modal-close").click

    # Statement two has no picture, so there is nothing to reframe — the pill
    # has to go with the pager rather than sit there doing nothing.
    within("[data-card-cid='t1']") { find(".tap-nav-btn[data-tap-stack-target='nextBtn']").click }
    assert_selector "[data-card-cid='t1'] .media-adjust-fab", visible: :hidden
    within("[data-card-cid='t1']") { find(".tap-nav-btn[data-tap-stack-target='prevBtn']").click }
    assert_selector "[data-card-cid='t1'] .media-adjust-fab", visible: :visible
  end

  test "on a desktop Reposition still reframes the hero, whichever statement is on top" do
    open_editor
    hero = card_data("cardImage")

    within("[data-card-cid='t1']") { find(".tap-nav-btn[data-tap-stack-target='nextBtn']").click }
    assert_selector "[data-card-cid='t1'] .media-adjust-fab", visible: :visible

    within("[data-card-cid='t1']") { find(".media-adjust-fab").click }
    assert_selector "[data-media-picker-target='posStage']", visible: true
    assert_includes mounted_pos_image, hero,
                    "the desktop panel's own picture is what its own pill reframes"
  end
end
