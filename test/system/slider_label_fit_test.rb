require "application_system_test_case"

# A scale word is never printed with a word broken in half.
#
# Five stops divide the answer panel into five equal columns, and a flex
# column cannot shrink below its longest WORD. At the player's 16px option
# size that is ~69px on a 390px phone, which "Definitely" (68px) and
# "Wouldn't" (65px) sit right on top of — so `overflow-wrap: break-word`, the
# rule that stops a label spilling over its neighbour, was firing as the
# ordinary case and the scale read "Wouldn' / t matter  …  Definitel / y".
#
# slider_controller#fitLabels takes two levers, and this walks the phones that
# make it take each one:
#   * shrink the scale to fit the widest word, down to --play-scale-floor;
#   * past the floor, and only where the card's slider_axis is `auto`, turn
#     the scale vertical, which gives every stop a full-width row.
#
# WHAT IS ACTUALLY MEASURED. Not "did the controller run" — the widest word on
# the card, drawn on a canvas at the size and family the label really computed
# to, against the width the column really has. That is the thing a respondent
# sees break, and it stays true whichever lever was pulled (or neither).
class SliderLabelFitTest < ApplicationSystemTestCase
  # The scale from the report: two words at the wide end, one long word at the
  # other, all inside the 17-character cap. Every one of them fits its column
  # at 13px and none of them does at 16.
  LABELS = [ "Wouldn't matter", "Not for me", "I might", "Probably", "Definitely" ].freeze

  # Wider than anything the cap allows to be shortened at the type's floor —
  # the case that has to become vertical rather than break.
  UNSHRINKABLE = [ "Uncomfortable", "Disagreeable", "Indifferent", "Comfortable", "Enthusiastic" ].freeze

  PHONES = {
    "iPhone 15"   => [ 393, 852 ],
    "iPhone SE"   => [ 375, 667 ],
    "small"       => [ 320, 568 ],
    "Galaxy Fold" => [ 280, 653 ]
  }.freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "fit-#{SecureRandom.hex(3)}")
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  def published(options, slider_axis: nil)
    card = { "type" => "range", "cid" => "r1", "options" => options,
             "text" => "If you had a say in how football is run, would you use it?" }
    card["slider_axis"] = slider_axis if slider_axis
    survey = @org.surveys.create!(
      title: "Fit", theme: "T", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hi" }, card ])
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  def open_range(survey, width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active .slider-label-text", wait: 5
    # The fit runs again when the webfont lands, and ABeeZee is wider than the
    # fallback it measured against first.
    wait_until { evaluate_script("document.fonts.status") == "loaded" }
  end

  # Per label: the column it was given, the size it computed to, and the width
  # of its widest word drawn at that size. Weight 700 because the chosen stop
  # bolds, and a stop that fits until it is picked is the same bug one tap on.
  def scale_metrics
    evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const ctx  = document.createElement("canvas").getContext("2d")
        return [...card.querySelectorAll(".slider-labels:not(.nps-slider-labels) .slider-label-text")].map(el => {
          const cs = getComputedStyle(el)
          ctx.font = `700 ${cs.fontSize} ${cs.fontFamily}`
          const words = el.textContent.trim().split(/\\s+/).filter(Boolean)
          return {
            text: el.textContent.trim(),
            size: parseFloat(cs.fontSize),
            column: el.getBoundingClientRect().width -
                    parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight),
            widest: Math.max(...words.map(w => ctx.measureText(w).width))
          }
        })
      })()
    JS
  end

  def axis
    evaluate_script(%{document.querySelector(".preview-card.active .slider-wrap").dataset.sliderAxisValue})
  end

  # --play-scale-floor in resolved pixels, read from the stylesheet rather
  # than restated here (the same trick player_type_floor_test uses): a
  # deliberate retune moves the token and this test follows it.
  def scale_floor
    evaluate_script(<<~JS)
      (() => {
        const probe = document.createElement("span")
        probe.style.cssText = "position:absolute;visibility:hidden;font-size:var(--play-scale-floor)"
        document.querySelector(".preview-overlay").appendChild(probe)
        const px = parseFloat(getComputedStyle(probe).fontSize)
        probe.remove()
        return px
      })()
    JS
  end

  PHONES.each do |name, (w, h)|
    test "no scale word is broken in half at #{name} (#{w}x#{h})" do
      open_range(published(LABELS), w, h)
      floor = scale_floor

      scale_metrics.each do |m|
        assert_operator m["widest"], :<=, m["column"] + 0.5,
                        "#{name}: #{m['text'].inspect} has #{m['column'].round}px of column for a " \
                        "#{m['widest'].round}px word at #{m['size']}px — it will break mid-word"
        assert_operator m["size"], :>=, floor,
                        "#{name}: #{m['text'].inspect} rendered at #{m['size']}px, under the " \
                        "#{floor}px --play-scale-floor — the scale bought room it is not allowed to spend"
      end
    end
  end

  test "a scale too wide to shrink into turns vertical instead of breaking" do
    open_range(published(UNSHRINKABLE), 320, 568)

    assert_equal "vertical", axis,
                 "twelve-letter stops cannot fit a 320px phone's columns at the type's floor — " \
                 "the layout is the lever left, and it wasn't pulled"
    scale_metrics.each do |m|
      assert_operator m["widest"], :<=, m["column"] + 0.5,
                      "#{m['text'].inspect} is still broken in the vertical layout"
    end
  end

  # The floor is low on purpose. An earlier pass set it at 14px, which reads
  # like the gentler number and is not: "Somewhat" is 81px of word in a 69px
  # column on an ordinary phone, so the commonest scale in the product ran out
  # of type and turned vertical. Rotating a card is a far bigger change than
  # two points of caption, and this pins that it doesn't happen.
  test "an everyday agreement scale stays horizontal on a phone" do
    open_range(published([ "Not at all", "A little", "Somewhat", "Fairly", "Very" ]), 393, 660)

    assert_equal "horizontal", axis,
                 "a five-word scale on a 393px phone should fit by type alone"
    scale_metrics.each do |m|
      assert_operator m["widest"], :<=, m["column"] + 0.5,
                      "#{m['text'].inspect} will break mid-word"
    end
  end

  # The flip is the `auto` layout resolving itself with the real column width
  # in hand. A creator who picked horizontal from the toggle keeps horizontal,
  # and falls back to the wrap-at-any-cost guard the stylesheet still carries.
  test "a creator's explicit horizontal is not overruled" do
    open_range(published(UNSHRINKABLE, slider_axis: "horizontal"), 320, 568)

    assert_equal "horizontal", axis, "the card said horizontal and the fit overrode it"
    assert_operator scale_metrics.map { |m| m["size"] }.min, :>=, scale_floor,
                    "the scale kept shrinking past its floor rather than stopping at it"
  end

  # Widening the panel back must give the type back: a fit that only ever
  # shrinks leaves a rotated phone reading a scale sized for a narrow one.
  test "the scale returns to full size when there is room again" do
    survey = published(LABELS)
    open_range(survey, 375, 667)
    narrow = scale_metrics.map { |m| m["size"] }.min
    assert_operator narrow, :<, 16, "nothing was fitted at 375px, so there is nothing to give back"

    page.driver.browser.resize(width: 844, height: 500)
    wait_until { scale_metrics.map { |m| m["size"] }.min > narrow }

    assert_operator scale_metrics.map { |m| m["size"] }.min, :>, narrow,
                    "the scale stayed at its narrow-phone size after the viewport grew"
  end
end
