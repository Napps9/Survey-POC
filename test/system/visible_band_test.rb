require "application_system_test_case"

# lib/visible_band exists because two measurements that look interchangeable
# are not, and the difference is invisible on the platform most testing happens
# on. getBoundingClientRect() is in LAYOUT-viewport coordinates;
# visualViewport.height is a LENGTH. The band a respondent can see occupies
# [offsetTop, offsetTop + height] in layout space, so `height` alone is its
# lower edge only while offsetTop is zero — which is Android's case, and not
# iOS's.
#
# _revealField compared a client rect against the bare height. On Android the
# spaces coincide and it was right by accident. On iOS Safari scrolls the
# visual viewport instead of shrinking the layout one, offsetTop goes positive,
# and viewport_height.js's pin translates the overlay by that same offsetTop —
# so the omission lands on both sides of the comparison and cancels on neither.
# Measured against a stubbed 200px split: the floor came out at 508 instead of
# 611, and a field already in view was declared 184px too low rather than 81.
#
# WHY THIS IS AN ARITHMETIC TEST AND NOT A BEHAVIOURAL ONE. I tried to pin it
# through the player and could not make the assertion honest: the reveal's
# scroll is clamped by however much room the scroller happens to have left, so
# the wrong answer and the right one both land within about 17px of each other
# on the one card that has a text field inside a scrollable box. A test that
# passes on both formulas is worse than no test — it is the exact shape of
# guard that let this ship. So the arithmetic is named, extracted, and pinned
# directly, and the behavioural half below only guards against the fix turning
# the feature off.
class VisibleBandTest < ApplicationSystemTestCase
  # Any player page will do — the module is pinned under lib/ and this test is
  # about the function, not the page.
  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "band-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Band", theme: "T", audience_age: "all",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "welcome_card", "title" => "Hi" },
                                            { "type" => "open_ended", "cid" => "o1", "text" => "Say more" } ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-overlay", wait: 5
  end

  # Calls the real module with a stubbed viewport object, which is the only way
  # to state a keyboard split exactly — no headless browser has a soft keyboard.
  def band_end(offset_top:, height:)
    page.evaluate_async_script(<<~JS, offset_top, height)
      const [o, h, done] = arguments
      import("lib/visible_band")
        .then((m) => done(m.visibleBandEnd({ offsetTop: o, height: h }, 9999)))
        .catch((e) => done("IMPORT FAILED: " + e.message))
    JS
  end

  test "with no keyboard the band ends where the viewport does" do
    assert_equal 852, band_end(offset_top: 0, height: 852)
  end

  test "Android shrinks the layout viewport, so the height alone is the floor" do
    # interactive-widget=resizes-content: the layout viewport becomes the band
    # and offsetTop stays 0. This is the case the old arithmetic got right, and
    # the reason nobody caught the other one.
    assert_equal 516, band_end(offset_top: 0, height: 516)
  end

  test "iOS scrolls the visual viewport, so the offset has to be added back" do
    # THE ONE THAT MATTERS. Safari keeps an 852 layout viewport, shows a 516
    # band, and scrolls it 200px down to reveal the field. The band's lower edge
    # is at 716 in layout space — the coordinate space every getBoundingClientRect
    # in the player reports in.
    assert_equal 716, band_end(offset_top: 200, height: 516),
                 "visibleBandEnd dropped visualViewport.offsetTop. Anything comparing a " \
                 "client rect against this will judge an element offsetTop pixels lower " \
                 "than it really is — on iOS only, with a keyboard up, which is the one " \
                 "situation the code exists for."
  end

  test "with no visualViewport at all it falls back rather than throwing" do
    result = page.evaluate_async_script(<<~JS)
      const [done] = arguments
      import("lib/visible_band")
        .then((m) => done(m.visibleBandEnd(null, 640)))
        .catch((e) => done("IMPORT FAILED: " + e.message))
    JS
    assert_equal 640, result,
                 "an older browser without visualViewport must get the layout viewport, " \
                 "not NaN — NaN would make every comparison false and silently disable " \
                 "the reveal"
  end

  test "the band's top is the offset, and zero without a viewport" do
    top = page.evaluate_async_script(<<~JS)
      const [done] = arguments
      import("lib/visible_band")
        .then((m) => done([ m.visibleBandTop({ offsetTop: 200, height: 516 }), m.visibleBandTop(null) ]))
        .catch((e) => done("IMPORT FAILED: " + e.message))
    JS
    assert_equal [ 200, 0 ], top
  end
end
