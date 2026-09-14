require "application_system_test_case"

# "In the editor on the mobile view, creators want to add images to the
# background on answer types where you can see the full screen, so taps, NPS
# etc — we need to allow creators to add that background and it not affect
# anything on the desktop or tablet side."
#
# Three types drop their hero strip on a phone because their ANSWER needs the
# whole card: a tap matrix, an NPS container, a prioritise list
# (CardTypes::FULL_SCREEN_ANSWER_TYPES, and hero_promise_test holds the reason
# per type). That made them the only cards a creator could not design for a
# phone at all — every other type shows its own picture there as a hero, and a
# backdrop was refused on anything carrying a picture on the grounds that the
# picture covers it. True of the desktop panel. Not true of a phone, which
# draws these no picture at all.
#
# So the backdrop is now allowed on exactly those three whatever else they
# carry, and it is a PHONE layer: it reaches the browser as --card-bg-* custom
# properties that only the phone blocks read, which is what keeps the desktop
# and tablet layouts out of it while both go on carrying the same attribute.
class MobileBackgroundTest < ApplicationSystemTestCase
  PHONE   = [ 390, 844 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  HERO = "/assets/verto-library/left-panel/sports-people-desktop-2.jpg".freeze
  BG   = "/assets/verto-library/mobile-backgrounds/sports-people-mobile-3.jpg".freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "mb-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Mb", email_address: "mb-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  # Every card carries BOTH a desktop hero and a mobile background, because the
  # whole point is that the two are separate designs for separate screens — a
  # fixture with only one of them cannot tell them apart.
  def build(live: true)
    survey = @org.surveys.create!(
      title: "Both", theme: "football", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "What is your call?",
          "options" => [ "Ticket prices", "Kick-off times" ],
          "image" => HERO, "media_bg" => { "image" => BG } },
        { "type" => "nps", "cid" => "n1", "text" => "How likely?",
          "image" => HERO, "media_bg" => { "image" => BG } },
        { "type" => "prioritise", "cid" => "p1", "text" => "In order, please.",
          "options" => [ "Cheaper", "Closer", "Friendlier" ],
          "image" => HERO, "media_bg" => { "image" => BG } },
        # The control: an ordinary card, which shows its picture as a hero on a
        # phone and must go on refusing a backdrop behind it.
        { "type" => "open_ended", "cid" => "o1", "text" => "Tell us more.",
          "image" => HERO, "media_bg" => { "image" => BG } }
      ]
    )
    survey.update_columns(publish_token: (live ? SecureRandom.hex(8) : nil),
                          published_at: (live ? Time.current : nil))
    survey
  end

  # What the card's panel is actually painting, and with which picture.
  def panel(cid)
    page.evaluate_script(<<~JS)
      (() => {
        const c  = document.querySelector("[data-card-cid='#{cid}']") ||
                   document.querySelector(".preview-card.active")
        const sl = c.querySelector(".split-left")
        const sc = c.querySelector(".split-card")
        const cs = getComputedStyle(sl)
        const r  = sl.getBoundingClientRect()
        const img = c.querySelector(".split-left-img")
        return {
          display: cs.display,
          position: cs.position,
          // clientHeight/Width, not the card's own rect: `inset: 0` resolves
          // against the containing block's PADDING box, and the editor gives
          // .split-card a border — so the backdrop is legitimately a border's
          // width shorter than the card measures.
          covers: r.height >= sc.clientHeight - 2 && r.width >= sc.clientWidth - 2,
          painted: cs.backgroundImage,
          heroShown: img ? getComputedStyle(img).display !== "none" : false,
          heroUrl: img ? getComputedStyle(img).backgroundImage : ""
        }
      })()
    JS
  end

  def open_editor(survey, device: nil)
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='t1'] .rotate-card", minimum: 2
    return unless device

    execute_script(%(document.querySelector(".device-toggle-btn[data-device='#{device}']").click()))
    assert_selector ".device-#{device}", wait: 5
  end

  # ── The phone shows it ──────────────────────────────────────────────────

  %w[t1 n1 p1].each do |cid|
    test "the #{cid} card paints its mobile background behind the whole card in the phone frame" do
      open_editor(build(live: false), device: "mobile")
      p = panel(cid)

      assert_equal "absolute", p["position"],
                   "the panel is not a backdrop — a hero strip in the flow takes height the " \
                   "answer on these three types cannot spare"
      assert p["covers"], "the backdrop does not cover the card"
      assert_includes p["painted"], BG,
                      "the card is painting #{p['painted']} — not the background the creator set"
      assert_not p["heroShown"],
                 "the DESKTOP picture is still drawn over the mobile background. The two are " \
                 "different designs for different screens, not two layers of one."
    end
  end

  # ── Desktop and tablet do not ───────────────────────────────────────────

  test "the desktop editor shows the card's own picture and never the mobile background" do
    open_editor(build(live: false))
    p = panel("t1")

    assert_not_equal "absolute", p["position"],
                     "the desktop panel became a full-card backdrop"
    assert_not_includes p["painted"], BG,
                        "the mobile background is painting on the desktop panel — the one thing " \
                        "this must not do"
    assert p["heroShown"], "the desktop panel stopped drawing the card's own picture"
    assert_includes p["heroUrl"], HERO
  end

  test "the tablet frame shows no mobile background either" do
    open_editor(build(live: false), device: "tablet")
    p = panel("t1")

    assert_not_includes p["painted"], BG,
                        "the tablet frame is drawing a phone-only layer, so a creator designing " \
                        "for a tablet is shown one the player does not draw"
  end

  # ── The player, which is what a respondent gets ─────────────────────────

  test "a respondent on a phone sees the background, and on a desktop sees the picture" do
    survey = build
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_text "What is your call?"
    assert_includes panel("t1")["painted"], BG,
                    "the phone player is not showing the creator's mobile background"

    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_text "What is your call?"
    p = panel("t1")
    assert_not_includes p["painted"], BG
    assert_includes p["heroUrl"], HERO
  end

  # THE BUG THIS FILE EXISTS FOR, SECOND TIME: "the pill shows but doesn't
  # work, it's changing the left hand card image not the background". The
  # control was offered and stored nothing, because it opened #open — the
  # card's OWN media picker, with the backdrop folded into a section below it.
  # Pick a photo, press Apply, and the card's hero changed under a heading that
  # said Background.
  test "Background stores a background, and leaves the card's own picture alone" do
    survey = build(live: false)
    open_editor(survey, device: "mobile")
    before = evaluate_script(%(document.querySelector("[data-card-cid='t1']").dataset.cardImage))

    within("[data-card-cid='t1']") { find(".card-bg-fab").click }
    # Open ON the background: the colour and Remove controls are what tell a
    # creator which slot they are filling, and #open buried them in a section
    # under the card's own media tabs.
    assert_selector "[data-media-picker-target='animBgSection']", visible: true

    tile = all("[data-media-picker-target='libraryItem']").find { |t| t[:"data-url"].present? }
    assert tile, "the background picker offered nothing to pick"
    picked = tile[:"data-url"]
    tile.click
    assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
    find("[data-media-picker-target='applyBtn']").click
    assert_no_selector ".media-modal-backdrop", visible: true

    stored = evaluate_script(%(document.querySelector("[data-card-cid='t1']").dataset.cardMediaBg))
    assert_equal picked, JSON.parse(stored.presence || "{}")["image"],
                 "Apply did not write the background"
    assert_equal before, evaluate_script(%(document.querySelector("[data-card-cid='t1']").dataset.cardImage)),
                 "Background rewrote the card's own picture — the whole of the report"
    assert_includes panel("t1")["painted"], picked,
                    "the card did not repaint with the background just chosen"
  end

  # "You need to be able to pick any media you wish as a mobile background."
  # The picker opens on the same sources a card's own picture gets — the
  # library, an upload, the stock search and the curated strip — not a
  # cut-down one.
  test "the background picker offers every source the card's own picture gets" do
    open_editor(build(live: false), device: "mobile")
    within("[data-card-cid='t1']") { find(".card-bg-fab").click }

    assert_selector ".media-modal-tabs", visible: true
    assert_selector "[data-media-picker-target='tab'][data-tab='library']", visible: true
    assert_selector "[data-media-picker-target='tab'][data-tab='upload']", visible: true
    assert_selector "[data-media-picker-target='libraryItem']", minimum: 1
    assert_selector "[data-media-picker-target='searchInput']", visible: true
  end

  test "the phone's Background control is offered on a card that already has a picture" do
    open_editor(build(live: false), device: "mobile")

    within("[data-card-cid='t1']") do
      assert_selector ".card-bg-fab", text: "Background", visible: true
      # …alongside, not instead of: the card's own picture is still the
      # desktop panel's and still has its controls.
      assert_selector ".add-media-fab", text: "Change media", visible: true
    end
  end
end
