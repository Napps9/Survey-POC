require "application_system_test_case"

# Phase 2 of the mobile studio: at phone width the editor becomes the card a
# respondent sees, with the creator's chrome floating over it.
#
# What is asserted is the MECHANISM, because that is what can silently rot:
# the feed must be wearing .preview-overlay (the player's own phone scope, the
# thing that makes the card respondent-true without a line of player CSS being
# copied) and the desktop editor must show no sign of any of it.
class MobileStudioShellTest < ApplicationSystemTestCase
  PHONE   = [ 390, 844 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "ms-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Ms", email_address: "ms-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "Pocket Verto", theme: "workplace", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Hello" },
                                     { "type" => "yes_no", "cid" => "c1", "text" => "First question?",
                                       "options" => %w[Yes No] },
                                     { "type" => "multiple_choice", "cid" => "c2", "text" => "Second question?",
                                       "options" => [ "Alpha", "Beta" ] }
                                   ])
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_editor(width, height)
    page.driver.browser.resize(width: width, height: height)
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "First question?"
  end

  test "the phone editor wears the player's own card scope and floats its chrome" do
    open_editor(*PHONE)

    stage = evaluate_script(<<~JS)
      (() => {
        const feed = document.querySelector(".editor-feed")
        const card = document.querySelector(".survey-card-wrap .split-card")
        return {
          player: feed.classList.contains("preview-overlay"),
          studio: feed.classList.contains("m-studio"),
          bezel: feed.classList.contains("device-mobile") || feed.classList.contains("device-tablet"),
          root: document.querySelector(".m-studio-on") !== null,
          cardWidth: Math.round(card.getBoundingClientRect().width),
          cardDirection: getComputedStyle(card).flexDirection,
          vw: window.innerWidth
        }
      })()
    JS
    assert stage["player"], "the feed must carry .preview-overlay — that IS the respondent's card layout"
    assert stage["studio"], "the feed must carry .m-studio"
    assert_not stage["bezel"], "the preview bezel must never coexist with the real phone layout"
    assert stage["root"], "the editor root must carry .m-studio-on so the chrome shows"
    assert_equal stage["vw"], stage["cardWidth"], "the card should be full-bleed"
    assert_equal "column", stage["cardDirection"], "the card should be stacked, as a respondent sees it"

    # The chrome is visible, thumb-sized, and floating ABOVE the card.
    chrome = evaluate_script(<<~JS)
      (() => {
        const box = (sel) => {
          const el = document.querySelector(sel)
          if (!el) return null
          const r = el.getBoundingClientRect()
          const cs = getComputedStyle(el)
          return { h: Math.round(r.height), top: Math.round(r.top), display: cs.display,
                   position: cs.position, z: cs.zIndex }
        }
        return { topbar: box(".m-topbar"), dock: box(".m-dock"), footer: box(".m-footer"),
                 rail: getComputedStyle(document.querySelector(".card-rail")).display,
                 floatBar: getComputedStyle(document.querySelector(".editor-float-bar")).display,
                 dockBtn: Math.min(...[...document.querySelectorAll(".m-dock-btn")]
                            .map(el => el.getBoundingClientRect().height)) }
      })()
    JS
    assert_equal "fixed", chrome["topbar"]["position"], "the top bar floats over the card"
    assert_operator chrome["topbar"]["z"].to_i, :>, 60, "chrome must sit above the card stage (z 60)"
    assert_operator chrome["dockBtn"], :>=, 44, "a dock button came out under 44px"
    assert_equal "none", chrome["rail"], "the 148px desktop card rail has no place on a phone"
    assert_equal "none", chrome["floatBar"], "the desktop float bars are replaced by the chrome"
  end

  test "the deck footer pages through the cards" do
    open_editor(*PHONE)

    chip = -> { find(".m-progress-chip").text }
    # The pager walks .card-slot — the deck's cards. Read the total off the
    # DOM rather than hardcoding it, so adding a gate or a thank-you block to
    # the feed later changes the app's answer, not this test's expectation.
    total = evaluate_script("document.querySelectorAll('.card-slot').length")
    assert_equal 3, total, "three cards were seeded"
    assert_equal "Card 1 of #{total}", chip.call

    find(".m-footer .preview-btn-next").click
    assert_equal "Card 2 of #{total}", chip.call

    find(".m-footer .preview-btn-back").click
    assert_equal "Card 1 of #{total}", chip.call
  end

  test "renaming from the title pill reaches the saved Verto" do
    open_editor(*PHONE)

    pill = find(".m-title-text")
    pill.click
    # Replace the whole name, then commit with Enter as a phone keyboard would.
    pill.send_keys([ :control, "a" ], "Pocket Verto Renamed", :enter)

    assert_text "Saved", wait: 10
    assert_equal "Pocket Verto Renamed", @survey.reload.title
  end

  test "the desktop editor shows no trace of the phone shell" do
    open_editor(*DESKTOP)

    facts = evaluate_script(<<~JS)
      (() => {
        const feed = document.querySelector(".editor-feed")
        return {
          player: feed.classList.contains("preview-overlay"),
          studio: feed.classList.contains("m-studio"),
          root: document.querySelector(".m-studio-on") !== null,
          chrome: getComputedStyle(document.querySelector(".m-chrome")).display,
          rail: getComputedStyle(document.querySelector(".card-rail")).display,
          floatBar: getComputedStyle(document.querySelector(".editor-float-bar")).display
        }
      })()
    JS
    assert_not facts["player"], "the desktop feed must not be re-classed"
    assert_not facts["studio"]
    assert_not facts["root"]
    assert_equal "none", facts["chrome"], "the phone chrome must be invisible on desktop"
    assert_not_equal "none", facts["rail"], "the desktop card rail must survive"
    assert_not_equal "none", facts["floatBar"], "the desktop float bars must survive"
  end
end
