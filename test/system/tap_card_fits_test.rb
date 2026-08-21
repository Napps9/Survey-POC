require "application_system_test_case"

# A swipe card fits the phone; the phone does not scroll the swipe card.
#
# Scrolling is the wrong verb for this card — you swipe it — and a respondent
# who has to drag the page to see the bottom two answers will read that as the
# card being broken. The desktop floor of 430px was forcing exactly that: 73px
# of scroll on an iPhone SE, 143px on a 320x480.
#
# The card is now fluid and floors at 260 in the player, so it takes whatever
# the panel has. The catch is that a shorter card FLATTENS THE ARC — the fan's
# vertical radius is 22% of the card's height — so the rows close on each other
# as it shrinks. The answers give height back in step (--tap-pill-h is 12cqh,
# read off the card itself), and these tests hold both ends of that bargain: the
# card must fit, AND the answers must still clear each other once it has.
#
# Measured floors, for whoever tunes this next: with a fixed 56px pill the rows
# touch at 380px on a five-point scale and 320px on a six-point one. Five is the
# tighter of the two — its middle rows sit 14.84% of the card apart against
# six's 17.51% — so five is the scale that governs.
class TapCardFitsTest < ApplicationSystemTestCase
  STATEMENTS = [ "Meetings drain me", "I get deep work done" ].freeze

  # Every upright phone in player_type_floor_test's matrix. A landscape phone is
  # deliberately absent — 844x390 gives the card 228px, less than five answers
  # can be drawn in, so that one still scrolls a little and says so below.
  UPRIGHT = {
    "Galaxy Fold" => [ 280, 653 ],
    "iPhone SE"   => [ 375, 553 ],
    "iPhone 15"   => [ 393, 660 ],
    "tall phone"  => [ 390, 844 ]
  }.freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "fits-#{SecureRandom.hex(3)}")
  end

  def deck(count)
    survey = @org.surveys.create!(
      title: "Fits #{count}", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome" },
        { "type" => "tap_card", "cid" => "t1", "text" => "React to these",
          "options" => STATEMENTS.dup, "responses" => TapScales.preset(count) }
      ]
    )
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  def open_player(survey, width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".preview-card.active [data-tap-response]", minimum: 2, wait: 5
  end

  # One reading of the live card: how far the answer area still hides, and how
  # close the closest pair of answers came.
  def fit_report
    evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const box  = card.querySelector(".split-right > .mt-2")
        const pills = [...card.querySelectorAll("[data-tap-response]")]
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
        return {
          hidden: box ? Math.round(box.scrollHeight - box.clientHeight) : 0,
          card: Math.round(card.querySelector(".rotate-card-stack").getBoundingClientRect().height),
          overlaps,
          gap: gap === Infinity ? null : Math.round(gap)
        }
      })()
    JS
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  # The widest scale on the narrowest phones is the case that has to hold: six
  # answers is the most the card can be asked to draw, and the Fold is the least
  # room it will ever be given upright.
  UPRIGHT.each do |device, (w, h)|
    test "a six-answer swipe card fits a #{device} (#{w}x#{h}) without scrolling" do
      open_player(deck(6), w, h)
      r = fit_report

      assert_equal 0, r["hidden"],
                   "#{device}: #{r['hidden']}px of the swipe card is below the fold. A respondent " \
                   "should never scroll a card they are meant to swipe — the card is #{r['card']}px " \
                   "and the panel could not take it."
    end
  end

  # Fitting is only half of it. The card shrinks to fit by flattening its own
  # arc, so a card that fits and whose answers now sit on top of each other has
  # traded one broken layout for another.
  [ 5, 6 ].each do |count|
    UPRIGHT.each do |device, (w, h)|
      test "#{count} answers still clear each other on a #{device}" do
        open_player(deck(count), w, h)
        r = fit_report

        assert_equal 0, r["overlaps"],
                     "#{device}: #{r['overlaps']} pair(s) of answers overlap on a #{r['card']}px card"
        assert_operator r["gap"], :>=, 3,
                        "#{device}: the closest two answers are #{r['gap']}px apart on a " \
                        "#{r['card']}px card — they clear, but only just. The pill is sized off " \
                        "the card (--tap-pill-h: 12cqh) precisely so this stays comfortable."
      end
    end
  end

  # The card is fluid, so it should actually be BIGGER where there is room —
  # otherwise the floor is doing all the work and the growth is decorative.
  #
  # This used to assert `tall > short + 100`, on the reasoning that a big
  # difference proves growth. That stopped being the right test when the stack
  # gained a mobile CAP: a tall phone now reaches the cap instead of running on
  # to the base rule's 560px, so the honest gap narrowed to ~67px and the
  # assertion failed on a card that was working perfectly. The cap is
  # deliberate — 320x448 rather than 320x560, because 1.75 read as a column
  # rather than a card and left nothing above or below it.
  #
  # So the question the test asks has moved: not "is the difference large" but
  # "is each phone getting what it should" — the tall one its cap, the short
  # one less than that because it genuinely cannot afford it, and NEITHER of
  # them the 260px floor. That still catches the failure this file exists for
  # (the stack collapsing to its floor when the flex growth chain breaks, which
  # _fitCard's over() cannot see), and it no longer fails when the cap works.
  #
  # The cap is read from the CSS rather than restated here, the same trick
  # player_type_floor_test uses: a deliberate retune moves the rule and this
  # follows it; an accidental collapse still fails.
  CSS = Rails.root.join("app/assets/tailwind/application.css").freeze

  def mobile_stack_cap
    body = File.read(CSS)[/\.preview-overlay \.rotate-card-stack \{([^}]*)\}/, 1]
    body[/max-height:\s*(\d+)px/, 1].to_i
  end

  def mobile_stack_floor
    body = File.read(CSS)[/\.preview-overlay \.rotate-card-stack \{([^}]*)\}/, 1]
    body[/min-height:\s*(\d+)px/, 1].to_i
  end

  test "the card grows into a tall phone rather than sitting at its floor" do
    cap, floor = mobile_stack_cap, mobile_stack_floor
    assert_operator cap, :>, floor, "the stack's cap and floor have crossed over"

    survey = deck(5)
    open_player(survey, 375, 553)
    short = fit_report["card"]

    open_player(survey, 390, 844)
    tall = fit_report["card"]

    assert_in_delta cap, tall, 6,
                    "a tall phone gave the card #{tall}px, not its #{cap}px cap. There is room " \
                    "for the whole card here, so anything less means the growth chain is broken " \
                    "and the stack is falling back toward its floor."
    assert_operator short, :>, floor + 40,
                    "a short phone dropped the card to #{short}px against a #{floor}px floor. " \
                    "Sitting ON the floor is the collapse this file exists to catch — nothing " \
                    "in the app can see it, because _fitCard's over() reads 0 either way."
    assert_operator tall, :>, short,
                    "the tall phone (#{tall}px) gave the card no more than the short one " \
                    "(#{short}px), so the card is not fluid at all any more."
  end
end
