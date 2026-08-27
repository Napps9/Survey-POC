require "application_system_test_case"

# Phase 1 of the mobile studio (M-STUDIO block in application.css): the
# dashboard and the share panel are the first creator surfaces with a real
# phone layout. Geometry is asserted, not class names — the promise is "a
# thumb can use this", which is a matter of pixels.
#
# Touch-target heights are read with offsetHeight, NOT
# getBoundingClientRect().height. The rect maps through ancestor transforms
# and comes back as a float, and .dashboard-card is a composited layer (it
# carries a transform transition and hover handlers that swap transform),
# with the hero's gen-orb-drift animations keeping frames flowing behind it.
# A 44px min-height therefore measures 43.99993896484375 — 44 minus 2^-14,
# float noise rather than a layout value — often enough to redden CI roughly
# one run in five. offsetHeight is the integer layout height and is exactly
# what "is this 44px of thumb" means. The sheet's edge-to-edge geometry below
# still uses the rect: that one genuinely wants viewport coordinates.
class MobileDashboardTest < ApplicationSystemTestCase
  PHONE   = [ 390, 844 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Mob", slug: "mob-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Mob", email_address: "mob-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "Mobile Snapshot", theme: "workplace", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Hi" },
                                     { "type" => "yes_no", "cid" => "c1", "text" => "Q?", "options" => %w[Yes No] }
                                   ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  test "at phone width the metrics pair up and tile actions are touch-sized" do
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    sign_in_as(@user)
    visit root_path
    dismiss_cookie_banner
    assert_selector ".dashboard-card"

    # Two metric columns, not five slivers and not one long stack.
    track_count = evaluate_script(
      "getComputedStyle(document.querySelector('.dash-metrics-grid')).gridTemplateColumns.split(' ').length"
    )
    assert_equal 2, track_count, "phone metrics should sit two across"

    # Every action on a tile is at least the iOS touch minimum.
    min_h = evaluate_script(<<~JS)
      Math.min(...[...document.querySelectorAll(".dash-card-actions a, .dash-card-actions button")]
        .map(el => el.offsetHeight))
    JS
    assert_operator min_h, :>=, 44, "a tile action came out under 44px"
  end

  test "at phone width the share panel is a bottom sheet flush with the screen" do
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    sign_in_as(@user)
    visit root_path
    dismiss_cookie_banner

    find("button[data-panel-url]").click
    assert_selector ".share-modal__head", wait: 5

    geo = evaluate_script(<<~JS)
      (() => {
        const r = document.querySelector(".share-modal__shell").getBoundingClientRect()
        return { left: r.left, width: r.width, bottom: r.bottom,
                 vw: window.innerWidth, vh: window.innerHeight }
      })()
    JS
    assert_in_delta 0,         geo["left"],   1, "sheet should hug the left edge"
    assert_in_delta geo["vw"], geo["width"],  1, "sheet should span the full width"
    assert_in_delta geo["vh"], geo["bottom"], 1, "sheet should sit on the bottom edge"

    # Copy button + channel chips are touch-sized inside the sheet.
    min_h = evaluate_script(<<~JS)
      Math.min(...[...document.querySelectorAll(".share-modal .share-btn")]
        .map(el => el.offsetHeight))
    JS
    assert_operator min_h, :>=, 44, "a share control came out under 44px"
  end

  test "the desktop dashboard and share modal are untouched" do
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    sign_in_as(@user)
    visit root_path
    dismiss_cookie_banner

    track_count = evaluate_script(
      "getComputedStyle(document.querySelector('.dash-metrics-grid')).gridTemplateColumns.split(' ').length"
    )
    assert_operator track_count, :>, 2, "desktop metrics should keep their wide auto-fit grid"

    find("button[data-panel-url]").click
    assert_selector ".share-modal__head", wait: 5
    geo = evaluate_script(<<~JS)
      (() => {
        const r = document.querySelector(".share-modal__shell").getBoundingClientRect()
        return { top: r.top, width: r.width, vw: window.innerWidth }
      })()
    JS
    assert_operator geo["top"], :>=, 60, "desktop share modal should float below the nav, not sheet to an edge"
    assert_operator geo["width"], :<, geo["vw"], "desktop share modal should not span the screen"
  end
end
