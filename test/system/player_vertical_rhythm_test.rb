require "application_system_test_case"

# "Text stuck up top and leaving large bits of white between" — pages 18-21 of
# the feedback sheet, on two different card families that got there two
# different ways.
#
# Family 1 (list, freeform, grid): the answer scroller was the panel's only
# flex-grow child, so it swallowed every spare pixel. That left
# .split-right's `justify-content: safe center` with nothing to centre — the
# question pinned flush to the top of the panel, the widget auto-margin-centred
# in the inflated box below it, and the slack painted as white in two places.
#
# Family 2 (range, and rating/yes_no with a hero): the panel is content-sized,
# so justify-content was already a no-op. Its white was never inside the panel
# at all — the hero above is capped at --play-hero-h, and whatever the cap
# wouldn't let it take stacked up UNDER the panel as .split-card's own
# background. 189px of it on an iPhone 15 range card; 260px on a rating card.
#
# Both are measured here, and measured as SYMMETRY rather than as an absolute:
# the size of the slack is a design variable, but slack landing entirely above
# or entirely below the content is the bug in either family.
class PlayerVerticalRhythmTest < ApplicationSystemTestCase
  PHONE   = [ 393, 852 ].freeze
  SMALL   = [ 375, 667 ].freeze
  # Cuprite keeps ONE browser for the whole run — a suite that exits
  # phone-sized breaks every test scheduled after it. Restore in teardown.
  DESKTOP = [ 1280, 900 ].freeze

  CARDS = [
    { "type" => "range", "cid" => "r1", "text" => "How likely are you to recommend us?",
      "description" => "Drag the slider to whatever feels right.",
      "options" => (0..10).map(&:to_s) },
    { "type" => "multiple_choice", "cid" => "m1", "text" => "Which of these did you use?",
      "description" => "Pick the one closest to your experience.",
      "options" => [ "Alpha", "Beta", "Gamma" ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "rhythm-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Rhythm", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player(size = PHONE)
    page.driver.browser.resize(width: size[0], height: size[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  # Advance until the named type is on screen. The deck has no welcome card, so
  # the entry point is already the first question — walking by name rather than
  # counting Nexts keeps this readable if a card is ever added in front.
  def goto(type)
    4.times do
      return if find(".preview-card.active")["data-card-type"] == type
      click_button "Next"
      sleep 0.5
    end
    flunk "never reached a #{type} card"
  end

  # Slack above the question vs slack below the answer, both inside the panel's
  # padding box, plus any white left under the panel in the card.
  #
  # `below` is measured to the WIDGET, not to its .mt-2 wrapper, and that is
  # the whole point. In the bug, the wrapper filled the panel edge to edge —
  # so wrapper-to-panel slack was 0 top and bottom and read as perfectly
  # balanced — while the widget floated auto-margin-centred inside it with all
  # the white split above and below ITSELF. Measure the box and you measure
  # nothing; measure what the respondent can see and the asymmetry appears.
  def rhythm
    page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const sc = card && card.querySelector(".split-card")
        const sr = card && card.querySelector(".split-right")
        const qh = sr && sr.querySelector(":scope > .q-header")
        const mt = sr && sr.querySelector(":scope > .mt-2")
        const w  = mt && (mt.firstElementChild || mt)
        if (!sc || !sr || !qh || !w) return null
        const cs = getComputedStyle(sr), b = sr.getBoundingClientRect()
        return {
          type:   card.dataset.cardType,
          above:  qh.getBoundingClientRect().top - b.top - parseFloat(cs.paddingTop),
          gap:    w.getBoundingClientRect().top - qh.getBoundingClientRect().bottom,
          below:  b.bottom - w.getBoundingClientRect().bottom - parseFloat(cs.paddingBottom),
          under:  sc.getBoundingClientRect().bottom - b.bottom,
          over:   mt.scrollHeight - mt.clientHeight
        }
      })()
    JS
  end

  # The slack a card actually has to distribute. Under ~24px there is nothing
  # to centre and the assertion would be measuring rounding.
  def assert_centred(r, note)
    slack = r["above"] + r["below"]
    return if slack < 24

    assert_in_delta r["above"], r["below"], [ slack * 0.25, 8 ].max,
                    "#{note}: #{r['above'].round}px of slack above the question and " \
                    "#{r['below'].round}px below the answer. The panel centres its content; " \
                    "slack landing on one side means something in it is growing and " \
                    "justify-content has nothing left to work with."

    # ...and the question and its answer must read as ONE block. The old
    # layout balanced above/below perfectly well while pushing them to
    # opposite ends of the panel with the entire slack stranded between them.
    assert_operator r["gap"], :<, [ r["above"], 40 ].max + 12,
                    "#{note}: #{r['gap'].round}px between the question and its answer, " \
                    "against #{r['above'].round}px of slack above. That is the gap the owner " \
                    "photographed — the pair is supposed to sit together in the middle of " \
                    "the panel, not at either end of it."
  end

  test "a list card centres its question and answer instead of pinning them to the top" do
    open_player
    goto "multiple_choice"

    r = rhythm
    assert_equal "multiple_choice", r["type"]
    assert_centred r, "list card, iPhone 15"
    assert_equal 0, r["over"],
                 "this card fits comfortably; if it is suddenly scrolling, the answer " \
                 "container has stopped being able to shrink"
  end

  test "a range card leaves no band of white under its answer" do
    open_player
    goto "range"

    r = rhythm
    assert_equal "range", r["type"]
    # The panel is content-sized here, so the fix had to be a different
    # mechanism: it grows into the leftover the hero's ceiling won't let the
    # picture take. 189px measured before that change.
    assert_operator r["under"], :<=, 8,
                    "#{r['under'].round}px of the card sits empty under the answer panel — " \
                    "this is the band on page 18 of the feedback sheet, and it is " \
                    ".split-card's own background showing through, not padding"
    assert_centred r, "range card, iPhone 15"
  end

  test "the rhythm holds on a small phone too" do
    open_player(SMALL)
    goto "range"
    assert_centred rhythm, "range card, iPhone SE"

    goto "multiple_choice"
    assert_centred rhythm, "list card, iPhone SE"
  end

  # The question's own three lines had NO spacing rule at all: .q-header was
  # not a flex container, carried no gap, and none of .q-eyebrow / .q-title /
  # .q-subtitle had a margin. Both gaps measured literally 0px — every bit of
  # apparent separation was line-height leading, which is why the per-type
  # instruction read as glued to the question.
  test "the question header spaces its eyebrow, title and description" do
    open_player
    goto "multiple_choice" # the card in this deck with all three header lines

    gaps = page.evaluate_script(<<~JS)
      (() => {
        const qh = document.querySelector(".preview-card.active .split-right > .q-header")
        if (!qh) return null
        const kids = Array.from(qh.children).map((k) => k.getBoundingClientRect())
        return kids.slice(1).map((k, i) => k.top - kids[i].bottom)
      })()
    JS

    assert gaps, "no question header found"
    assert_operator gaps.size, :>=, 2, "expected an eyebrow, a title and a description"
    gaps.each do |g|
      assert_operator g, :>=, 4,
                      "a gap inside the question header is #{g.round}px. These were 0 — the " \
                      "header had no spacing rule of any kind — so this is a change from " \
                      "zero, and a tidy-up that drops the gap puts it straight back."
    end
  end
end
