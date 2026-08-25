require "application_system_test_case"

# Test Mode is a yellow ring around the viewport, not a strip across the top
# of it.
#
# The strip was ~31px, taken off the top of the card in the one mode where the
# card is already short: --play-card-h is a MEASUREMENT rather than a CSS
# estimate precisely because things stack above the deck inside the overlay,
# and the Test Mode banner was one of the two things that do (a notch is the
# other). "In test mode remove the banner at the top of the screen, have a
# yellow outline around the screen but don't take up any space."
#
# Nothing rendered a real Test Mode page in a browser before this file, so
# "takes up no space" was unverifiable in either direction. It is measured
# here the only way that means anything: against the same deck NOT in test
# mode. Same viewport, same cards — the card must start at the same height.
class TestModeFrameTest < ApplicationSystemTestCase
  W = 393
  H = 768

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "frame-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Frame", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "cid" => "w", "title" => "Welcome" },
        { "type" => "multiple_choice", "cid" => "m", "text" => "Which of these?",
          "options" => [ "Alpha", "Beta", "Gamma" ] }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  def open(path)
    page.driver.browser.resize(width: W, height: H)
    visit path
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    sleep 0.4
  end

  def ordinary_url = "/play/#{@survey.publish_token}"
  def testing_url  = "/test/live/#{@survey.publish_token}"

  # Where the deck starts, relative to the top of the overlay it lives in.
  def deck_top
    page.evaluate_script(<<~JS)
      (() => {
        const ov = document.querySelector(".preview-overlay")
        const body = document.querySelector(".preview-body")
        return Math.round(body.getBoundingClientRect().top - ov.getBoundingClientRect().top)
      })()
    JS
  end

  # THE assertion. Everything else in this file is about the ring behaving; this
  # is the one that says it cost nothing, and it can only be said by comparison.
  test "test mode costs the card no height at all" do
    open(ordinary_url)
    ordinary = deck_top

    open(testing_url)
    testing = deck_top

    assert_selector ".play-test-frame", visible: :all
    assert_in_delta ordinary, testing, 1,
                    "the deck starts #{testing}px down in Test Mode against #{ordinary}px in " \
                    "an ordinary play. Something is in the overlay's flow above the card — " \
                    "which is the banner this change removed, in whatever form it came back. " \
                    "The ring has to be out of flow to cost nothing."
  end

  test "the ring is drawn, in yellow, on all four edges" do
    open(testing_url)
    r = page.evaluate_script(<<~JS)
      (() => {
        const f = document.querySelector(".play-test-frame")
        if (!f) return null
        const cs = getComputedStyle(f)
        const ov = document.querySelector(".preview-overlay").getBoundingClientRect()
        const fr = f.getBoundingClientRect()
        return { shadow: cs.boxShadow, position: cs.position, pointer: cs.pointerEvents,
                 z: cs.zIndex,
                 covers: Math.round(fr.width - ov.width) === 0 &&
                         Math.round(fr.height - ov.height) === 0 }
      })()
    JS

    assert r, "there is no .play-test-frame on a Test Mode page"
    assert_match(/inset/, r["shadow"],
                 "the ring is not an inset box-shadow (#{r['shadow']}). A border would sit " \
                 "inside this element's border-box and shrink the card by the very pixels " \
                 "the strip used to take, which would make the change a no-op.")
    assert_match(/255,\s*250,\s*119/, r["shadow"], "the ring is not the Test Mode yellow")
    assert r["covers"], "the ring does not span the whole overlay, so it is not a ring"
    assert_equal "absolute", r["position"],
                 "the ring is #{r['position']}. Fixed is wrong here: lib/viewport_height puts " \
                 "a transform on the overlay while the keyboard is up, which makes the overlay " \
                 "the containing block and moves a fixed child's reference frame mid-session."
    assert_equal "none", r["pointer"],
                 "the ring takes pointer events. It covers the entire card, so every tap meant " \
                 "for an option lands on it instead."
  end

  # Position is not reachability. A full-card transparent layer that forgets
  # pointer-events: none measures perfectly and breaks everything under it.
  test "the ring never eats a tap meant for the card" do
    open(testing_url)
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".preview-card.active .choice-list-item", minimum: 3, wait: 5

    hit = page.evaluate_script(<<~JS)
      (() => {
        const opt = document.querySelector(".preview-card.active .choice-list-item")
        const r = opt.getBoundingClientRect()
        const el = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
        return { inside: !!el && (el === opt || opt.contains(el) || el.contains(opt)),
                 was: el ? String(el.className || el.tagName).slice(0, 40) : "nothing" }
      })()
    JS

    assert hit["inside"],
           "an option's own centre hit-tests to #{hit['was']} instead of the option. The ring " \
           "is painted over the card and is swallowing taps."
  end

  # The ring says "this is different". It cannot say "nothing you enter is
  # saved", and that sentence is the only warning a tester ever gets.
  test "Test Mode still says, in words, that nothing is saved" do
    open(testing_url)

    assert_selector ".play-test-note", text: I18n.t("player.test_mode_banner"), visible: :all

    size = page.evaluate_script(<<~JS)
      (() => {
        const n = document.querySelector(".play-test-note")
        const r = n.getBoundingClientRect()
        const cs = getComputedStyle(n)
        return { w: Math.round(r.width), h: Math.round(r.height), display: cs.display }
      })()
    JS

    assert_operator size["w"], :<=, 1,
                    "the note is #{size['w']}px wide — it is being drawn, which is the strip " \
                    "coming back by another name."
    assert_not_equal "none", size["display"],
                     "the note is display: none, so a screen reader loses it too and NOTHING " \
                     "anywhere tells a tester their answers are not being kept. Clipped, not " \
                     "hidden — that is the whole distinction."
  end

  # The ring outlines the card, so it has to be above everything drawn on top
  # of the card, or its edges are broken by whatever wins.
  test "the ring paints above the controls it has to outline" do
    open(testing_url)
    zs = page.evaluate_script(<<~JS)
      (() => {
        const z = s => { const el = document.querySelector(s)
          return el ? parseInt(getComputedStyle(el).zIndex, 10) || 0 : null }
        return { frame: z(".play-test-frame"), footer: z(".preview-footer") }
      })()
    JS

    assert_operator zs["frame"], :>, zs["footer"],
                    "the ring (#{zs['frame']}) sits under the floating controls " \
                    "(#{zs['footer']}), so the pills cut a hole in the bottom edge."
  end
end
