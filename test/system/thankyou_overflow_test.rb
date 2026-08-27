require "application_system_test_case"

# A thank-you screen can outgrow the player. Points, a leaderboard and four
# CTAs stack up, and short viewports are ordinary: a phone in the one-pager's
# laptop mockup, a small handset, anything in landscape.
#
# It used to sit inside two vertically centred boxes — .preview-thankyou and
# .preview-body — and centred overflow spills equally in BOTH directions. The
# half above the top is then unreachable, because browsers create no scrollable
# area before the origin. The top of a long thank-you wasn't merely off-screen,
# it could not be scrolled to. Reproduced at 390x240, where the card's own top
# sat at -24px with the only scrollable ancestor set to overflow: hidden.
class ThankyouOverflowTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "open_ended", "cid" => "c1", "text" => "Anything else?" }
  ].freeze

  def setup
    super
    org = Organisation.create!(name: "O", slug: "tyover-#{SecureRandom.hex(3)}")
    @survey = org.surveys.create!(
      title: "Overflow", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      thankyou_title: "Thanks for taking part!",
      thankyou_body: "There's plenty more to explore."
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def play_to_the_end
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".preview-card.active .freeform-wrap", wait: 5
    find("[data-player-target='finishBtn']").click
    assert_selector ".preview-thankyou.active", wait: 8
  end

  # A short *window* won't do: Chromium clamps its window to roughly 500px, so
  # the layout would quietly stay tall enough to hide the bug.
  def with_viewport(width, height)
    page.driver.browser.page.command("Emulation.setDeviceMetricsOverride",
                                     width: width, height: height,
                                     deviceScaleFactor: 1, mobile: true)
    yield
  ensure
    page.driver.browser.page.command("Emulation.clearDeviceMetricsOverride")
  end

  test "a thank-you taller than the viewport starts at the top and scrolls" do
    with_viewport(390, 240) do
      play_to_the_end

      box = page.evaluate_script(<<~JS)
        (() => {
          const wrap = document.querySelector('.preview-thankyou.active');
          const card = document.querySelector('.preview-thankyou-card');
          const cs = getComputedStyle(wrap);
          return { cardTop: Math.round(card.getBoundingClientRect().top),
                   wrapTop: Math.round(wrap.getBoundingClientRect().top),
                   overflowY: cs.overflowY,
                   scrollH: wrap.scrollHeight, clientH: wrap.clientHeight };
        })()
      JS

      assert_operator box["scrollH"], :>, box["clientH"],
        "this viewport is meant to be too short for the card — the test proves nothing otherwise"
      assert_operator box["cardTop"], :>=, box["wrapTop"] - 1,
        "the card starts above its container, which is the half a browser will not let you scroll to"
      assert_includes %w[ auto scroll ], box["overflowY"],
        "the thank-you must scroll itself: .preview-body clips it with overflow: hidden"

      # And the overflow is genuinely reachable, not just present.
      reached = page.evaluate_script(<<~JS)
        (() => {
          const w = document.querySelector('.preview-thankyou.active');
          w.scrollTop = w.scrollHeight;
          return w.scrollTop > 0;
        })()
      JS
      assert reached, "the bottom of the thank-you can't be scrolled to"
    end
  end

  test "a thank-you that fits is still centred" do
    # The fix must not top-align every ordinary thank-you: auto margins take the
    # spare room when there is any and collapse to zero when there isn't.
    with_viewport(390, 900) do
      play_to_the_end

      gaps = page.evaluate_script(<<~JS)
        (() => {
          const wrap = document.querySelector('.preview-thankyou.active');
          const card = document.querySelector('.preview-thankyou-card');
          const w = wrap.getBoundingClientRect(), c = card.getBoundingClientRect();
          return { above: Math.round(c.top - w.top), below: Math.round(w.bottom - c.bottom) };
        })()
      JS
      assert_in_delta gaps["above"], gaps["below"], 2,
        "the card should sit centred when there is room for it (#{gaps.inspect})"
      assert_operator gaps["above"], :>, 20, "no spare room here — this case proves nothing"
    end
  end
end
