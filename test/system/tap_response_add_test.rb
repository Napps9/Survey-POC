require "application_system_test_case"

# Adding and removing a swipe card's ANSWERS in the editor, across the point
# where the strip changes shape.
#
# tap_card_scale_test covers the shipped five-point card in the player; this
# covers the creator building one by hand, which is where the shape change is a
# live DOM edit rather than a server render. Past four the strip stops being a
# row and fans across the photo, and that is a two-element change: the strip
# takes itself out of flow (.rotate-actions--fan is inset: 0), and the scrim it
# sits in has to become a card-height box for it to stretch inside
# (.rotate-card-controls--fan). The server partial and the type panel both
# render the pair together; card_editor rewrites only the strip, so nothing but
# a test holds the second half in place.
#
# What it looked like when the second half was missing: click ＋ on a four-point
# scale, and the parent — still the short bar it is in row mode, and now with no
# in-flow children at all — collapsed to its own padding. Every pill's
# --tap-x/--tap-y then resolved against ~49px instead of the card's 430, so the
# five answers landed in a heap on top of each other at the foot of the card.
# Hence the overlap assertion: the classes agreeing is the mechanism, but pills
# not sitting on each other is the thing a creator actually cares about.
class TapResponseAddTest < ApplicationSystemTestCase
  STATEMENTS = [ "Meetings drain me", "I get deep work done" ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tra-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tra", email_address: "tra-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    # Three answers and no stored `responses`: the default every existing Verto
    # is on, and the state a creator starts adding from.
    @survey = @org.surveys.create!(
      title: "Tap", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "React to these",
          "options" => STATEMENTS.dup }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='t1'] [data-tap-response]", count: 3
  end

  def add_response
    before = page.all("[data-card-cid='t1'] [data-tap-response]").size
    find("[data-card-cid='t1'] .tap-response-add").click
    assert_selector "[data-card-cid='t1'] [data-tap-response]", count: before + 1
  end

  def remove_last_response
    before = page.all("[data-card-cid='t1'] [data-tap-response]").size
    row = page.all("[data-card-cid='t1'] [data-tap-response]").last
    row.hover
    row.find(".tap-response-delete", visible: :all).click
    assert_selector "[data-card-cid='t1'] [data-tap-response]", count: before - 1
  end

  # Whether the strip and the scrim it sits in agree about being fanned.
  def fan_state
    evaluate_script(<<~JS)
      (() => {
        const strip = document.querySelector("[data-card-cid='t1'] [data-tap-responses]")
        const controls = strip && strip.closest(".rotate-card-controls")
        return {
          strip: !!(strip && strip.classList.contains("rotate-actions--fan")),
          controls: !!(controls && controls.classList.contains("rotate-card-controls--fan"))
        }
      })()
    JS
  end

  # How many pairs of answers physically sit on top of each other.
  def overlapping_pairs
    evaluate_script(<<~JS)
      (() => {
        const rects = [...document.querySelectorAll("[data-card-cid='t1'] [data-tap-response]")]
          .map((el) => el.getBoundingClientRect())
        let n = 0
        for (let i = 0; i < rects.length; i++) {
          for (let j = i + 1; j < rects.length; j++) {
            const a = rects[i], b = rects[j]
            if (a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top) n++
          }
        }
        return n
      })()
    JS
  end

  # The dots say which statement of the deck you are on, and they belong inside
  # the card at every scale. Up to four answers the controls wrapper's 14px of
  # bottom padding gives them that; past four the fan zeroes the padding so the
  # strip can cover the whole photo, and the dots — the only in-flow child left —
  # went with it, landing on the card's rounded bottom edge.
  #
  # Asserted as a distance from the card's bottom rather than a class, because
  # the fix is a margin and the thing that matters is the gap a creator sees.
  def dots_clearance
    evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector("[data-card-cid='t1']")
        const dots = card.querySelector(".rotate-dots")
        const stack = card.querySelector(".rotate-card-stack")
        if (!dots || !stack) return null
        return Math.round(stack.getBoundingClientRect().bottom - dots.getBoundingClientRect().bottom)
      })()
    JS
  end

  test "the dots stay inside the card at every scale, not just the narrow ones" do
    open_editor

    row = dots_clearance
    assert_operator row, :>=, 10,
                    "at three answers the dots should already sit clear of the card's bottom edge"

    2.times { add_response }   # 3 -> 5, where the strip fans
    assert_operator dots_clearance, :>=, 10,
                    "on a fanned card the dots are pressed against the bottom edge — the fan " \
                    "zeroes the wrapper's padding, so they need their own clearance"
    assert_equal row, dots_clearance,
                 "the dots should sit the same distance inside the card whichever shape the " \
                 "strip is in; a scale that moves its own progress dots reads as two components"
  end

  test "the strip and its scrim agree about fanning, all the way up and back down" do
    open_editor

    seen = {}
    3.times do
      add_response
      seen[page.all("[data-card-cid='t1'] [data-tap-response]").size] = fan_state
    end
    4.times do
      remove_last_response
      seen[page.all("[data-card-cid='t1'] [data-tap-response]").size] = fan_state
    end

    seen.each do |count, state|
      assert_equal TapScales.fan?(count), state["strip"],
                   "at #{count} answers the strip's own fan class is wrong"
      assert_equal state["strip"], state["controls"],
                   "at #{count} answers the strip says fan=#{state['strip']} and the scrim it " \
                   "sits in says #{state['controls']} — one without the other is the layout bug"
    end
  end

  # Every pin on a card is one box. Sized to their own text they ran 23% to 32%
  # of the card wide — "Agree" against "Strongly disagree" — which read as a
  # ragged set of labels rather than one scale.
  #
  # offsetWidth/Height rather than a bounding rect, because a rect includes
  # transforms and these pills grow 7% under the pointer. Deleting an answer
  # leaves the mouse over its neighbour, so a rect would report that one pill
  # bigger than the rest and fail on the hover rather than on the layout. The
  # laid-out box is what "the same size" means here anyway.
  #
  # Whole pixels: a fixed percentage of a 320px card lands on a fraction, and
  # two pills can differ in the sub-pixel without differing to anyone looking.
  def pill_boxes
    evaluate_script(<<~JS)
      (() => {
        const pills = [...document.querySelectorAll("[data-card-cid='t1'] [data-tap-response]")]
        return pills.map((p) => `${Math.round(p.offsetWidth)}x${Math.round(p.offsetHeight)}`)
      })()
    JS
  end

  test "every answer on a fanned card is the same size" do
    open_editor

    2.times { add_response }   # 3 -> 5, the first size that fans
    assert_equal 1, pill_boxes.uniq.size,
                 "five answers came out in #{pill_boxes.uniq.size} different sizes: #{pill_boxes.tally.inspect}"

    add_response               # -> 6
    assert_equal 1, pill_boxes.uniq.size,
                 "six answers came out in #{pill_boxes.uniq.size} different sizes: #{pill_boxes.tally.inspect}"

    # Not the same size at BOTH counts, and deliberately so: the six-answer arc
    # brings its middle pair within 28.5% of the card of each other where the
    # five-answer one keeps its closest pair 36.9% apart, so one width can't
    # serve both without either colliding at six or wasting the card at five.
    six = pill_boxes.first
    remove_last_response       # -> 5
    assert_equal 1, pill_boxes.uniq.size
    assert_not_equal six, pill_boxes.first,
                     "five and six should NOT share a pill size — six has to be narrower for its " \
                     "middle pair to clear. Equal here means one of the two is wrong."
  end

  test "answers never land on top of each other, at any size a creator can build" do
    open_editor
    assert_equal 0, overlapping_pairs, "three answers overlap before anything was even clicked"

    3.times do |i|
      add_response
      count = i + 4
      assert_equal 0, overlapping_pairs,
                   "adding the #{count}th answer put answers on top of each other"
    end
  end

  # The panel's 2-6 picker reports the same number the ＋ and × change, so it has
  # to follow them. It used to update only when a card was selected: add two to a
  # three-point scale and the panel went on claiming 3 beside a card showing 5.
  test "the answers-per-statement picker follows the strip" do
    open_editor
    # A first click opens the panel; the second selects the card. The wrap's
    # centre lands on the swipe card, whose own handler stops propagation, so
    # both go to a corner.
    wrap = find("[data-card-cid='t1'] .rotate-wrap")
    2.times { wrap.click(x: 4, y: 4) }
    assert_selector ".response-scale-btn.is-active", text: "3"

    add_response
    assert_selector ".response-scale-btn.is-active", text: "4",
                    wait: 3

    add_response
    assert_selector ".response-scale-btn.is-active", text: "5"
    assert_equal 1, page.all(".response-scale-btn.is-active").size,
                 "exactly one size is the current one"

    remove_last_response
    assert_selector ".response-scale-btn.is-active", text: "4"
  end
end
