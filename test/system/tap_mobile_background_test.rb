require "application_system_test_case"

# "On mobile, on the tap card Q, when you click Change media, it does actually
# upload — but to the left hand side on desktop 😂 so the current change media
# button is not mobile specific, it replaces the main desktop asset and not the
# mobile background. The platform is uploading the background, just putting it
# in the wrong place."
#
# The upload was never in the wrong place. The picture is the card's own, and
# on a phone it simply had nowhere to be drawn: a tap card drops its hero STRIP
# there (the stack carries a picture per statement, so a band of a second photo
# above it read as torn imagery) and "no strip" had been read as "no picture"
# ever since. So a creator designing on a phone set something they could not
# see, on the one surface they were designing for.
#
# It is the background now: behind the whole card, with the question and the
# stack floating on it as a white panel. Which makes the pill honest without
# rewiring it — "Change media" changes the picture in front of you, because the
# picture in front of you is the card's.
class TapMobileBackgroundTest < ApplicationSystemTestCase
  PHONE   = [ 390, 844 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  HERO = "/assets/verto-library/left-panel/sports-people-desktop-2.jpg".freeze
  STATEMENT_IMAGE = "/assets/verto-library/swipe-cards/tap-card-photo-3.jpg".freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tb-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tb", email_address: "tb-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  # `bare:` is the card that must keep the OLD behaviour — no picture, no
  # panel at all — because that is the reasoning this change narrows rather
  # than replaces.
  def build(bare: false)
    survey = @org.surveys.create!(
      title: "Tap", theme: "football", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "What is your call?",
          "options" => [ "Tickets supporters can't afford", "Kick-off times for TV" ],
          "option_images" => [ STATEMENT_IMAGE, "" ] }.merge(bare ? {} : { "image" => HERO })
      ]
    )
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  def play(survey, width: PHONE[0], height: PHONE[1])
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_text "What is your call?"
  end

  # Where the card's picture is being drawn, measured rather than inferred from
  # a class: the panel's own box against the card's.
  def panel_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const c  = document.querySelector(".preview-card.active") || document.querySelector("[data-card-cid='t1']")
        const sl = c.querySelector(".split-left")
        const sc = c.querySelector(".split-card")
        const cs = getComputedStyle(sl)
        const r  = sl.getBoundingClientRect()
        const cr = sc.getBoundingClientRect()
        const img = c.querySelector(".split-left-img")
        return {
          display: cs.display,
          position: cs.position,
          coversCard: r.height >= cr.height - 1 && r.width >= cr.width - 1,
          painted: img ? getComputedStyle(img).backgroundImage : null
        }
      })()
    JS
  end

  # ── The player ──────────────────────────────────────────────────────────

  test "on a phone the card's picture is drawn behind the whole card" do
    play(build)
    g = panel_geometry

    assert_equal "absolute", g["position"],
                 "the panel is still a strip in the card's flow — a backdrop is out of the flow, " \
                 "which is what lets the stack keep the whole card"
    assert g["coversCard"],
           "the panel does not cover the card, so the picture is a band again rather than a " \
           "background"
    assert_includes g["painted"].to_s, HERO,
                    "the picture behind the card is not the card's own image"
  end

  test "a tap card with no picture still has no panel at all" do
    play(build(bare: true))

    assert_equal "contents", panel_geometry["display"],
                 "a pictureless tap card grew a panel box. The strip is dropped for a reason " \
                 "that still holds — this change gives the picture somewhere to go, it does not " \
                 "hand the box back to a card that has nothing to put in it."
  end

  test "on a desktop the picture is still the left half of the card" do
    play(build, width: DESKTOP[0], height: DESKTOP[1])
    g = panel_geometry

    assert_not_equal "absolute", g["position"],
                     "the desktop card lost its left panel — the backdrop is the PHONE's " \
                     "treatment, and desktop has a half of the card to show the picture in"
    assert_includes g["painted"].to_s, HERO
  end

  # ── The editor, which is where Jamie was ────────────────────────────────

  test "the phone frame's Change media fills the picture the creator can see" do
    survey = @org.surveys.create!(
      title: "Tap", theme: "football", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "What is your call?",
          "options" => [ "Tickets supporters can't afford", "Kick-off times for TV" ],
          "option_images" => [ STATEMENT_IMAGE, "" ], "image" => HERO }
      ]
    )
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='t1'] .rotate-card", minimum: 2

    execute_script(%(document.querySelector(".device-toggle-btn[data-device='mobile']").click()))
    assert_selector ".device-mobile", wait: 5
    assert_equal "absolute", panel_geometry["position"],
                 "the editor's phone frame is not drawing the backdrop the player draws — the " \
                 "creator is designing against a phone that does not exist"

    within("[data-card-cid='t1']") { find(".add-media-fab").click }
    tile = all("[data-media-picker-target='libraryItem']").find { |t| t[:"data-url"].present? }
    assert tile, "the Verto Library rendered no pickable tile"
    picked = tile[:"data-url"]
    tile.click
    assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
    find("[data-media-picker-target='applyBtn']").click
    assert_no_selector ".media-modal-backdrop", visible: true

    card = ->(key) { evaluate_script(%(document.querySelector("[data-card-cid='t1']").dataset.#{key} || "")) }
    assert_equal picked, card.call("cardImage"),
                 "the pill filled something other than the picture on screen"
    assert_includes panel_geometry["painted"].to_s, picked,
                    "the stored picture changed but the card's background did not repaint"
    assert_equal [ STATEMENT_IMAGE, "" ], JSON.parse(card.call("cardOptionImages")),
                 "the background pick reached into the statements, which have their own control"
  end
end
