require "application_system_test_case"

# A range card's stops and the words under them are one object, and they were
# laid out as two.
#
# The dots sit at i/(n-1) along the track; the labels divided the same row into
# n equal columns, whose centres are at (i+0.5)/n. Those agree in the middle and
# nowhere else — on the 359px desktop track the two outer labels printed 39px
# INSIDE their own dot and the second and fourth 20px off theirs. Nothing about
# that is visible to a test that asserts on markup, and it is the first thing
# visible to a respondent, so it is measured here in a real browser.
#
# The second half is what happens when the words genuinely don't fit: the
# fallback used to be that they didn't, and broke mid-word rather than
# admitting it ("disag / ree" across three lines of a phone column). The scale
# now drops to its two ends and names the chosen stop above the track instead
# (slider_controller#_fitLabels), which is a decision made from the width the
# panel actually handed it — the thing NpsHelper#resolved_slider_axis, counting
# characters on the server, cannot know.
class SliderScaleFitTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze
  # The phone from the report. Narrow enough that five multi-word stops cannot
  # be printed side by side at the player's 16px, whatever is done to them.
  PHONE   = [ 390, 844 ].freeze

  # Short enough to fit five columns on a desktop card, so "fits" and "doesn't"
  # are both reachable from one deck by changing only the viewport.
  SCALE = [ "Not ready", "Somewhat ready", "Unsure", "Ready", "Very ready" ].freeze

  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "title" => "Welcome" },
    { "type" => "range", "cid" => "r1", "text" => "How ready do you feel?",
      "options" => SCALE },
    # Explicitly vertical: the label column had the same fault as the row, half
    # a band's worth, and it is a different set of rules that fixes it.
    { "type" => "range", "cid" => "r2", "text" => "And how does that land?",
      "slider_axis" => "vertical",
      "options" => [ "Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree" ] },
    { "type" => "open_ended", "cid" => "r3", "text" => "Anything else?" }
  ].freeze

  # Sub-pixel layout figures either side of a rounding: a stop is on its dot or
  # it is 20-40px off it, and nothing in between is a thing this can produce.
  TOLERANCE = 1.5

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "scale-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Scale", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # Cuprite keeps one browser for the whole run, so a test that resizes and
  # doesn't put it back breaks every later test that assumed the default.
  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_at(width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"   # past the welcome card
    assert_selector ".preview-card.active .slider-wrap", wait: 5
  end

  # Where each stop's dot is, and where its label is, on whichever axis the
  # card is laid out — so one measurement covers both layouts.
  def stops(axis: "horizontal")
    page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const mid  = (el, axis) => {
          const r = el.getBoundingClientRect()
          return axis === "vertical" ? r.top + r.height / 2 : r.left + r.width / 2
        }
        const axis = #{axis.to_json}
        const labels = [...card.querySelectorAll(".slider-labels .slider-label-text")]
        return [...card.querySelectorAll(".s-dot")].map((dot, i) => {
          const label = labels[i]
          const r = label.getBoundingClientRect()
          return {
            text:    label.textContent.trim(),
            shown:   r.width > 0 && r.height > 0,
            dot:     mid(dot, axis),
            centre:  mid(label, axis),
            near:    axis === "vertical" ? r.bottom : r.left,
            far:     axis === "vertical" ? r.top    : r.right
          }
        })
      })()
    JS
  end

  def condensed?
    page.evaluate_script(<<~JS)
      document.querySelector(".preview-card.active .slider-labels").classList.contains("is-condensed")
    JS
  end

  def readout
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".preview-card.active .slider-readout")
        return el && !el.hidden ? el.textContent.trim() : null
      })()
    JS
  end

  def label_size
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".preview-card.active .slider-label-text")
        return el ? parseFloat(getComputedStyle(el).fontSize) : null
      })()
    JS
  end

  # Lines per SHOWN label — the ladder's promise is about what is on the card,
  # and a hidden middle label reports a height of zero either way.
  def line_counts
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".preview-card.active .slider-labels .slider-label-text")]
        .map(el => {
          const r = el.getBoundingClientRect()
          if (!r.height) return 0
          return Math.round(r.height / parseFloat(getComputedStyle(el).lineHeight))
        })
    JS
  end

  test "every stop's label sits under its own dot" do
    open_at(*DESKTOP)

    measured = stops
    assert_equal SCALE, measured.map { |s| s["text"] }
    assert measured.all? { |s| s["shown"] }, "a desktop card has room for all five stops"

    measured.each do |stop|
      assert_in_delta stop["dot"], stop["centre"], TOLERANCE,
        "#{stop['text'].inspect} is #{(stop['centre'] - stop['dot']).round}px from its own dot"
    end
  end

  test "a vertical scale's labels sit beside their own dots" do
    open_at(*DESKTOP)
    click_button "Next"
    assert_selector '.preview-card.active .slider-wrap[data-slider-axis-value="vertical"]', wait: 5

    stops(axis: "vertical").each do |stop|
      assert_in_delta stop["dot"], stop["centre"], TOLERANCE,
        "#{stop['text'].inspect} is #{(stop['centre'] - stop['dot']).round}px from its own dot"
    end
  end

  test "a scale too wide for its words keeps the ends and names the choice" do
    open_at(*PHONE)

    assert condensed?, "five multi-word stops cannot be printed across a 390px phone"

    measured = stops
    assert measured.first["shown"],  "the low end still has to say what low means"
    assert measured.last["shown"],   "so does the high end"
    assert_equal [ false, false, false ], measured[1..3].map { |s| s["shown"] },
      "the middle stops come out — that is what buys the ends their room"

    # The ends still mark the ends: their outer edges are on the outer dots.
    assert_in_delta measured.first["dot"], measured.first["near"], 2,
      "the first label has to start on the first dot"
    assert_in_delta measured.last["dot"], measured.last["far"], 2,
      "the last label has to end on the last dot"

    assert_equal "Unsure", readout,
      "with the middle labels gone, the readout is the only thing naming the answer"
  end

  test "the readout follows the thumb" do
    open_at(*PHONE)
    assert condensed?

    execute_script('document.querySelector(".preview-card.active .slider-wrap").focus()')
    page.driver.browser.keyboard.type(:Right)

    assert_equal "Ready", readout
    assert_equal "Ready", page.evaluate_script(<<~JS), "the announced value moves with it"
      document.querySelector(".preview-card.active .slider-wrap").getAttribute("aria-valuetext")
    JS
  end

  # The reading-preference pill reaches the scale's words now (it used to stop
  # at .pick-text, so the one respondent who needed it most got it everywhere
  # except the card they had to aim at) — and the ladder is what makes that
  # affordable, so both halves are pinned together: the words grow, and no stop
  # ever spills past two lines however big they get.
  test "the text-size pill reaches the scale's words without breaking them" do
    open_at(*DESKTOP)

    before = label_size
    assert before, "no scale label to measure"

    %w[large larger].each do |step|
      find(".font-scale-btn[data-scale='#{step}']").click
      sleep 0.3   # the fit pass runs off a ResizeObserver

      assert_operator label_size, :>, before, "the #{step} step didn't reach the scale's words"
      assert_operator line_counts.max, :<=, 2,
        "a stop ran to #{line_counts.max} lines at #{step} instead of dropping to the ends"
    end
  end

  test "the labels a respondent cannot see are still the labels the card has" do
    open_at(*PHONE)
    assert condensed?

    # Hidden, not removed. Every stop is still reachable — by drag, by arrow
    # key, and by a screen reader reading aria-valuetext off the same nodes —
    # so a condensed scale is a scale with quieter labels, not a shorter one.
    assert_equal SCALE, page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".preview-card.active .slider-labels .slider-label-text")]
        .map(el => el.textContent.trim())
    JS
    assert_equal "4", page.evaluate_script(<<~JS)
      document.querySelector(".preview-card.active .slider-wrap").getAttribute("aria-valuemax")
    JS
  end
end
