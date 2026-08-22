require "application_system_test_case"

# The desktop player drew a fixed 850x680 card inside a centred, overflow:hidden
# .preview-body — so on any window shorter than the card plus its chrome (the
# lang bar, an org masthead, a Test Mode strip, the 80px footer) the overflow
# split evenly and the TOP half vanished with no scroll path. The top of a card
# is its instruction eyebrow: "The 'how to play' prompt for users is being cut
# off at the top of the card." A laptop at 1280x800 lost ~43px; an iPad mini in
# landscape ~86px. And with 0 bottom padding the card's lower edge sat flush on
# the footer's hairline: "Remove the boarder between the CTA's and the card,
# have the games CTA's floating to create more space. If the bottom of the card
# hits the CTAs move the card height to avoid the cta and the cards overlapping
# or touching."
#
# The fix consumes --play-card-h (measured from .preview-body by the player's
# own ResizeObserver — see player_card_box_test for that half of the story) at
# desktop: the card clamps between 520px and its classic 680px, the body gains
# the bottom padding that floats the CTAs, and below the floor the body scrolls
# flush-top instead of clipping. card_header_pinned_test cannot see any of
# this: it measures the header against .split-card's own rect, which moves WITH
# the card when the body clips it. These tests measure against the box the
# respondent actually sees.
class PlayerDesktopCtaClipTest < ApplicationSystemTestCase
  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "dcc-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Clip", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "w", "image" => "/nope.jpg",
          "text" => "Every way Verto can ask a question",
          "description" => "A short deck for measuring the desktop card box." },
        # The reported shape: a select list long enough that its top mattered.
        { "type" => "multiple_choice", "cid" => "l", "image" => "/nope.jpg",
          "text" => "Which industry do you work in?",
          "options" => [ "Arts & Culture", "Industry", "Transport & Logistics",
                         "IT & Media", "Finance & Banking", "Consulting",
                         "Education & Research", "Foundations" ] },
        { "type" => "range", "cid" => "r", "image" => "/nope.jpg",
          "text" => "How does that land?",
          "options" => [ "Not at all", "A little", "Some", "A lot", "Totally" ] }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  # Lands on the select list — the shape both report screenshots show, and a
  # card that (unlike welcome) carries the .q-header eyebrow being measured.
  def open_player(width, height, inset: 0)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    assert_selector ".preview-card.active", wait: 5
    click_button "Next"
    sleep 0.4
    assert_equal "multiple_choice", find(".preview-card.active")["data-card-type"]
    add_inset(inset) if inset.positive?
    sleep 0.4
  end

  # Anything stacked between the top of the overlay and the deck — a Test Mode
  # strip, an org masthead — shortens the card's box. Same mechanism as
  # player_card_box_test: injecting the strip IS the condition, not a stand-in.
  def add_inset(px)
    page.execute_script(<<~JS)
      const ov = document.querySelector(".preview-overlay")
      const strip = document.createElement("div")
      strip.style.cssText = "height:#{px.to_i}px;flex:0 0 auto;background:#272D4A"
      ov.insertBefore(strip, ov.firstChild)
    JS
    sleep 0.4
  end

  def box_report
    page.evaluate_script(<<~JS)
      (() => {
        const body   = document.querySelector(".preview-body")
        const card   = document.querySelector(".preview-card.active .split-card")
        const header = document.querySelector(".preview-card.active .q-header")
        const footer = document.querySelector(".preview-footer")
        const b = body.getBoundingClientRect()
        const c = card.getBoundingClientRect()
        return {
          cardH:      Math.round(c.height),
          cardTop:    Math.round(c.top - b.top),
          headerTop:  header ? Math.round(header.getBoundingClientRect().top - b.top) : null,
          footerGap:  Math.round(footer.getBoundingClientRect().top - c.bottom),
          footerRule: getComputedStyle(footer).borderTopWidth,
          bodyScroll: body.scrollHeight - body.clientHeight,
          bodyScrollTop: body.scrollTop
        }
      })()
    JS
  end

  test "a laptop window shrinks the card instead of clipping the question off the top" do
    open_player(1280, 800)
    box = box_report
    assert_operator box["cardTop"], :>=, 0,
                    "the card starts #{-box['cardTop']}px above the visible box — the top is unreachable"
    assert_operator box["headerTop"], :>=, 0, "the 'how to play' eyebrow is cut off the top of the card"
    assert_operator box["cardH"], :<, 680, "the card should have given up height to fit an 800px window"
    assert_in_delta 624, box["cardH"], 6,
                    "at 1280x800 the card should take the box less the CTA gap (got #{box['cardH']}px)"
  end

  test "an iPad mini in landscape fits its card without scrolling" do
    open_player(1024, 714)
    box = box_report
    assert_operator box["cardTop"], :>=, 0
    assert_operator box["headerTop"], :>=, 0
    assert_in_delta 538, box["cardH"], 6, "the shipping 1024x714 shape should sit above the floor un-floored"
    assert_operator box["bodyScroll"], :<=, 1, "nothing should need to scroll at this size"
  end

  test "chrome stacked above the deck shrinks the card instead of clipping it" do
    # A Test Mode strip (31px) plus an org masthead (54px), by mechanism.
    open_player(1280, 900, inset: 85)
    box = box_report
    assert_operator box["cardTop"], :>=, 0,
                    "with a banner and masthead above it the card's top went out of reach"
    assert_operator box["headerTop"], :>=, 0
    assert_operator box["cardH"], :<, 680
  end

  test "the standard desktop window keeps the classic card" do
    open_player(1280, 900)
    assert_in_delta 680, box_report["cardH"], 1,
                    "at 1280x900 nothing has changed and nothing should have"
  end

  test "below the floor the body scrolls flush-top rather than hiding the question" do
    open_player(1280, 620)
    box = box_report
    assert_in_delta 520, box["cardH"], 1, "the floor should hold — below it answers collapse"
    assert_operator box["bodyScroll"], :>, 0, "an over-tall card must be scrollable, not clipped"
    assert_equal 0, box["bodyScrollTop"], "the card should present its TOP first"
    assert_operator box["cardTop"], :>=, 0, "at scroll-zero the question must be the visible part"
  end

  test "no rule separates the CTAs from the card, and the card never touches them" do
    open_player(1280, 800)
    box = box_report
    assert_equal "0px", box["footerRule"],
                 "the desktop footer still draws its hairline — 'remove the boarder between " \
                 "the CTA's and the card'"
    assert_operator box["footerGap"], :>=, 20,
                    "the card sits #{box['footerGap']}px from the CTAs — they should float in clear space"
  end
end
