require "application_system_test_case"

# The phone footer's two behaviours, pinned in a real browser because neither
# survives a source-level assertion: one is decided by measuring text, the
# other by an event whose timing is the whole point.
class PlayerFooterTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "multiple_choice", "cid" => "c1", "text" => "Which colour?",
      "options" => %w[Red Blue Green] },
    { "type" => "rating", "cid" => "c2", "text" => "Rate it", "options" => [ "Poor", "Great" ] },
    { "type" => "range", "cid" => "c3", "text" => "How confident?",
      "options" => [ "Not at all", "A little", "Very" ] }
  ].freeze

  PHONE = [ 393, 660 ].freeze
  # Matches the driver's window_size (application_system_test_case.rb). These
  # tests are the only ones that resize the browser, and Cuprite keeps one
  # browser for the whole run — leaving it phone-sized made every editor test
  # that happened to run afterwards fail in a layout it was never written for.
  DESKTOP = [ 1280, 900 ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "foot-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Footer", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player(width: PHONE[0], height: PHONE[1])
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  def next_glowing?
    page.evaluate_script(
      "!!document.querySelector('.preview-btn-next')?.classList.contains('is-answered')"
    )
  end

  def footer_tight?
    page.evaluate_script(
      "!!document.querySelector('.preview-footer')?.classList.contains('is-tight')"
    )
  end

  # Chrome will hand back a stale computed style when it is read in the same
  # breath as the class change that caused it — the value is correct one frame
  # later. Poll for it rather than racing it; a wrong value still fails, it
  # just fails on the value instead of on the timing.
  def computed(selector, prop, pseudo: nil, expect:, timeout: 3)
    arg = pseudo ? ", '#{pseudo}'" : ""
    js  = "getComputedStyle(document.querySelector('#{selector}')#{arg}).#{prop}"
    deadline = Time.now + timeout
    actual = nil
    loop do
      actual = page.evaluate_script(js)
      break if actual == expect || Time.now > deadline
      sleep 0.05
    end
    actual
  end

  # ── The answered glow ────────────────────────────────────────────────────

  test "Next lights up only once the card holds an answer" do
    open_player
    click_button "Next" # past the welcome card

    assert_not next_glowing?, "an untouched question must not look answered"

    find(".preview-card.active li[role='radio']", match: :first).click

    assert_equal true, next_glowing?, "picking an option should light the button"
  end

  # rating_controller calls stopPropagation() on every pick, so a bubble-phase
  # listener never hears a star. This is the regression test for that: it fails
  # if the player's listener stops using the capture phase.
  test "a rating lights the button even though its widget stops the bubble" do
    open_player
    click_button "Next"
    find(".preview-card.active li[role='radio']", match: :first).click
    click_button "Next" # onto the rating

    assert_not next_glowing?

    find(".preview-card.active .rating-star", match: :first).click

    assert_equal true, next_glowing?, "a chosen star is an answer like any other"
  end

  # The other half of the timing bug: deferring the read with a microtask made
  # it run at the checkpoint BETWEEN listeners, i.e. before the picker had
  # selected anything, so a single tap left the button dark and only the next
  # unrelated event fixed it. One tap has to be enough.
  test "one tap is enough — the glow does not wait for a second event" do
    open_player
    click_button "Next"
    find(".preview-card.active li[role='radio']", match: :first).click

    assert_equal true, next_glowing?
  end

  # A Range renders with its thumb mid-scale and a dot already active, so
  # _read has a value for it from first paint. The button must not greet the
  # respondent already lit on a question they have not touched.
  test "a range card does not look answered before it is touched" do
    open_player
    click_button "Next"
    find(".preview-card.active li[role='radio']", match: :first).click
    click_button "Next"
    find(".preview-card.active .rating-star", match: :first).click
    click_button "Next" # onto the range

    assert_equal "range", page.evaluate_script(
      "document.querySelector('.preview-card.active').dataset.cardType"
    )
    assert_not next_glowing?, "an untouched slider is not an answer"
  end

  # ── The cramped-footer fallback ──────────────────────────────────────────

  test "the footer keeps its labels while they fit" do
    open_player

    assert_not footer_tight?
    assert_text "Next"
  end

  # Quiz mode swaps "Next →" for "Check answer", and in Ukrainian that is
  # "Перевірити відповідь" (config/locales/uk.yml) — the longest of the 19,
  # and half again the width of the English. No fixed breakpoint can be right
  # for every locale, so the bar measures instead: at 320px that label wants
  # ~128px and the button has ~119px to give it.
  test "a label too long for the bar collapses both buttons to arrows" do
    open_player(width: 320, height: 568)

    page.execute_script(<<~JS)
      const el = document.querySelector('[data-controller~="player"]')
      const c  = window.Stimulus.getControllerForElementAndIdentifier(el, "player")
      document.querySelector(".preview-btn-next").textContent = "Перевірити відповідь"
      c._fitFooter()
    JS

    assert footer_tight?, "a label that no longer fits should drop to an arrow"
    assert_equal "0px", computed(".preview-btn-next", "fontSize", expect: "0px"),
                 "the label is hidden so the arrow can stand in for it"
    assert_equal '"→"', computed(".preview-btn-next", "content", pseudo: "::before", expect: '"→"')
    assert_equal '"←"', computed(".preview-btn-back", "content", pseudo: "::before", expect: '"←"')
  end

  # On a desktop the buttons are content-sized, so a long label makes the
  # button wider rather than overflowing it. Collapsing there would be the
  # measurement misfiring, not the feature working.
  test "a wide viewport grows the button instead of collapsing it" do
    open_player(width: 1280, height: 800)

    page.execute_script(<<~JS)
      const el = document.querySelector('[data-controller~="player"]')
      const c  = window.Stimulus.getControllerForElementAndIdentifier(el, "player")
      document.querySelector(".preview-btn-next").textContent = "Vérifier la réponse"
      c._fitFooter()
    JS

    assert_not footer_tight?, "there is room on a desktop — nothing to collapse"
  end

  # ── Back and Next never outgrow the desktop card ─────────────────────────
  # The stacked layout used to stretch them to half the bar apiece, so an
  # upright iPad drew a 414px Next against desktop's 110px — four times the
  # size on a quarter of the screen. Desktop is the ceiling and mobile scales
  # down from it. Measured rather than hardcoded, so the rule still holds if
  # the desktop button is ever redrawn.

  # width, height at which to check the cap
  SCALED = [ [ 280, 653 ], [ 375, 553 ], [ 393, 660 ], [ 430, 730 ],
             [ 844, 390 ], [ 768, 954 ], [ 1024, 1290 ] ].freeze

  def next_button_box
    page.evaluate_script(<<~JS)
      (() => {
        const b = document.querySelector(".preview-btn-next:not(.hidden)")
        const r = b.getBoundingClientRect()
        return { w: r.width, h: r.height, fs: parseFloat(getComputedStyle(b).fontSize) }
      })()
    JS
  end

  def next_box_at(width, height)
    open_player(width: width, height: height)
    click_button "Next" # off the welcome card, onto a question
    next_button_box
  end

  test "no phone or tablet draws a bigger Next than the desktop card does" do
    desktop = next_box_at(1280, 900)

    SCALED.each do |w, h|
      got = next_box_at(w, h)

      assert got["w"] <= desktop["w"] + 1,
             "#{w}x#{h} drew a #{got["w"].round}px Next; desktop's is #{desktop["w"].round}px"
      assert got["fs"] <= desktop["fs"] + 0.1,
             "#{w}x#{h} set the label at #{got["fs"]}px; desktop's is #{desktop["fs"]}px"
      # Height is the one allowance: 44px is the smallest reliable touch
      # target and a pointer does not need one.
      assert got["h"] <= 44 + 1,
             "#{w}x#{h} drew a #{got["h"].round}px-tall Next; the touch floor is 44px"
    end
  end

  # Capped is not the same as shrunk to nothing — the label still has to be
  # readable on the narrowest screen anyone owns.
  test "the label keeps a floor as well as a ceiling" do
    box = next_box_at(280, 653)

    assert box["fs"] >= 11, "a 280px Fold cover screen set the label at #{box["fs"]}px"
  end
end
