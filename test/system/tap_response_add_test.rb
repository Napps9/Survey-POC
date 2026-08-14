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
