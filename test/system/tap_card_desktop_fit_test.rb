require "application_system_test_case"

# The tap card on a DESKTOP, which had no geometry test of its own —
# tap_card_fits_test is four phone viewports and reads the mobile cap out of the
# CSS, so neither of the two things reported here was visible to it:
#
#   "The tap cards on desktop have a weird scrollbar bottom and right hand
#    side. The cards feel slightly too large for the space."
#
# Two separate causes, one symptom.
#
# The scrollbars: _commit flings the answered card 120% out of the stack and
# leaves it there, because the fling IS the feedback. Its BOX goes with it, and
# a box 360px to the side of a 300px stack counts toward the scrollable overflow
# of the panel scroller it sits inside — .split-right > .mt-2, which is
# overflow-y: auto, and a scroll container clips on both axes, so overflow-x is
# auto too. On a phone that is invisible (overlay scrollbars); on a desktop it
# is a scrollbar along the bottom and another down the side, appearing on the
# first answer and going away again on Reset (which clears the transforms).
# tap-stack#_park is the fix: once the fling has played, the box goes back where
# it started.
#
# The size: the base rule's 430px floor against the ~457px the desktop panel
# can offer between the question and the reset row. An ordinary two-line
# question, or a shortish window, and the card no longer fitted the box it was
# centred in — a resting vertical scrollbar on a card nobody is meant to scroll.
#
# Asserted as the OUTCOME (no overflow on either axis) rather than the numbers,
# except for the shape itself, which is what was asked for.
class TapCardDesktopFitTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze
  STATEMENTS = [ "Not safe or affordable to play near home",
                 "Pitches are never free when I want them",
                 "Nobody asks what players think" ].freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "tapdesk-#{SecureRandom.hex(3)}")
  end

  # `question` is a local: a long one is the case that used to push the card
  # past its box, so both lengths are exercised.
  def deck(responses:, question: "React to these")
    survey = @org.surveys.create!(
      title: "Desk", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome" },
        { "type" => "tap_card", "cid" => "t1", "text" => question,
          "options" => STATEMENTS.dup, "responses" => TapScales.preset(responses) }
      ]
    )
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  def open_player(survey)
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active [data-tap-response]", minimum: 2, wait: 5
    settle_box find(".preview-card.active .rotate-card-stack")
  end

  # scrollWidth/scrollHeight against clientWidth/clientHeight on the scroller:
  # the same reading the browser uses to decide whether to draw a scrollbar, so
  # this is the symptom itself rather than a proxy for it.
  def overflow_report
    evaluate_script(<<~JS)
      (() => {
        const card  = document.querySelector(".preview-card.active")
        const box   = card.querySelector(".split-right > .mt-2")
        const stack = card.querySelector(".rotate-card-stack")
        const s = stack.getBoundingClientRect()
        return {
          x: Math.round(box.scrollWidth - box.clientWidth),
          y: Math.round(box.scrollHeight - box.clientHeight),
          w: Math.round(s.width),
          h: Math.round(s.height),
          ratio: +(s.height / s.width).toFixed(2)
        }
      })()
    JS
  end

  def answer_top_statement
    find(".preview-card.active [data-tap-response]", match: :first).click
  end

  # How many cards are still carrying a fling transform. The number that has to
  # reach zero: a parked card's box is back inside the stack.
  def flung_count
    evaluate_script(<<~JS)
      [...document.querySelectorAll(".preview-card.active .rotate-card")]
        .filter((c) => c.style.transform.includes("translate(")).length
    JS
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  test "a desktop tap card fits its panel with no scrollbar on either axis" do
    open_player(deck(responses: 2))
    r = overflow_report

    assert_equal 0, r["y"],
                 "the card overflows its scroller by #{r['y']}px vertically, so the panel draws " \
                 "the resting scrollbar down the side of a card nobody is meant to scroll"
    assert_equal 0, r["x"], "the panel scrolls sideways by #{r['x']}px"
  end

  # The reported one: it appears on the first answer, not on arrival.
  test "answering a statement does not put scrollbars on the panel" do
    open_player(deck(responses: 2))
    answer_top_statement

    assert wait_until(timeout: 5) { flung_count.zero? },
           "the answered card is still parked outside the stack (#{flung_count} flung), so its " \
           "box is still counted in the scroller's overflow"

    r = overflow_report
    assert_equal 0, r["x"],
                 "answering one statement put a #{r['x']}px horizontal scrollbar along the " \
                 "bottom of the card — the flung card's box is still in the scroller"
    assert_equal 0, r["y"], "answering one statement overflowed the panel by #{r['y']}px vertically"
  end

  test "a long question still leaves the card inside its panel" do
    open_player(deck(responses: 2,
                     question: "You are refereeing world football for a day. What is your call?"))
    r = overflow_report

    assert_equal 0, r["y"],
                 "a two-line question took #{r['y']}px more than the panel had — this is the " \
                 "case the old 430px floor could not fit"
    assert_equal 0, r["x"]
  end

  # The shape, which is the half that was asked for by eye: "reduce overall card
  # size (globally) a little less height and reduce width a bit... the
  # enterprise has these cards as closer to square (maybe a little taller)."
  test "the desktop card is close to square rather than a column" do
    open_player(deck(responses: 2))
    r = overflow_report

    assert_equal 300, r["w"], "the stack is #{r['w']}px wide, not the 300 the base rule sets"
    assert_operator r["h"], :<=, 400, "the stack grew past its 400px cap"
    assert_operator r["h"], :>=, 300, "the stack fell below its 300px floor"
    assert_operator r["ratio"], :<, 1.4,
                    "the card is #{r['w']}x#{r['h']} — a ratio of #{r['ratio']}. It was 1.34-1.75 " \
                    "before and the ask was squarer, so anything at or above the old best is a " \
                    "regression of the thing that was asked for"
  end

  # The fanned arc is what pays for a narrower card (every pixel taken off the
  # width closes the gap between the answers), so the widest scale is checked at
  # the new size — with the same 3px clearance floor tap_card_fits_test holds.
  test "a six-point scale still draws its answers clear of each other" do
    open_player(deck(responses: 6))

    report = evaluate_script(<<~JS)
      (() => {
        const pills = [...document.querySelectorAll(".preview-card.active [data-tap-response]")]
                        .map((p) => p.getBoundingClientRect())
        let overlaps = 0, gap = Infinity
        for (let i = 0; i < pills.length; i++) {
          for (let j = i + 1; j < pills.length; j++) {
            const a = pills[i], b = pills[j]
            if (a.left < b.right && a.right > b.left) {
              if (a.top < b.bottom && a.bottom > b.top) overlaps++
              gap = Math.min(gap, a.top < b.top ? b.top - a.bottom : a.top - b.bottom)
            }
          }
        }
        return { overlaps, gap: gap === Infinity ? null : Math.round(gap), count: pills.length }
      })()
    JS

    assert_equal 6, report["count"]
    assert_equal 0, report["overlaps"], "two of the six answers are drawn on top of each other"
    assert_operator report["gap"], :>=, 3,
                    "the closest pair of answers is #{report['gap']}px apart — under the 3px floor " \
                    "they start reading as one control" if report["gap"]
  end

  # Reset is the control that used to make the symptom disappear, which is how
  # the cause was found — so it has to keep working now that the card is parked.
  test "Reset brings a parked card back to the top of the stack" do
    open_player(deck(responses: 2))
    answer_top_statement
    assert wait_until(timeout: 5) { flung_count.zero? }

    find(".preview-card.active .rotate-reset-btn").click

    assert wait_until(timeout: 5) {
      evaluate_script(<<~JS)
        (() => {
          const top = document.querySelector(".preview-card.active .rotate-card")
          return top.style.opacity !== "0" && getComputedStyle(top).visibility === "visible"
        })()
      JS
    }, "after Reset the first statement is still hidden — parking outlived the reset"

    r = overflow_report
    assert_equal 0, r["x"]
    assert_equal 0, r["y"]
  end
end
