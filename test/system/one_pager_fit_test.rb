require "application_system_test_case"

# The laptop mockup in each one-pager hands the embedded player a fixed logical
# viewport and scales it into the screen area. The player's card is a fixed
# 850x680 box (.split-card) that nothing shrinks, so a viewport shorter than
# that clips it — centred, so the top goes first, which is exactly how this
# shipped once: 1000x567 cut 82px off the top of every card.
#
# Introspecting the frame needs same origin, so this visits a copy of the page
# served by the app. The file:// half of the contract lives in
# one_pager_embed_test.rb, where the frame is cross-origin and can't be
# measured. Every page in ONE_PAGERS gets the same three tests.
class OnePagerFitTest < ApplicationSystemTestCase
  # Named after its source, so two pages under test can't overwrite each
  # other's probe.
  def probe_path(pager)
    "public/__fit_probe_#{File.basename(pager, '.html')}.html"
  end

  def serve_probe_copy(pager, origin, token)
    one_pager_copy(pager, origin: origin, token: token, dest: probe_path(pager))
  end

  def published_survey
    org = Organisation.create!(name: "Fit Co", slug: "fit-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "Fit probe", theme: "Fit probe", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "text" => "Which of these matters most to you right now?",
          "options" => [ "Coffee", "Tea", "Water", "Energy drink" ] }
      ],
      publish_token: SecureRandom.urlsafe_base64(18),
      published_at: Time.current
    )
  end

  ONE_PAGERS.each do |pager|
    probe_url = "/__fit_probe_#{File.basename(pager, '.html')}.html"

    test "#{pager}: the embedded Verto is never clipped by the laptop screen" do
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      serve_probe_copy(pager, origin, survey.publish_token)

      visit "#{origin}#{probe_url}"
      assert_selector "#demoMockup.is-live", wait: 15

      card = within_frame(find(".screen-embed")) do
        page.evaluate_script(<<~JS)
          (() => {
            const el = document.querySelector('.split-card');
            if (!el) return null;
            const r = el.getBoundingClientRect();
            return { top: Math.round(r.top), bottom: Math.round(r.bottom),
                     left: Math.round(r.left), right: Math.round(r.right),
                     vw: window.innerWidth, vh: window.innerHeight };
          })()
        JS
      end

      assert card, "expected the player's card inside the embedded frame"
      assert_operator card["top"], :>=, 0,
        "the card's top is above the frame — the Verto is cut off, which is what a too-short logical viewport does"
      assert_operator card["bottom"], :<=, card["vh"],
        "the card runs past the bottom of the frame"
      assert_operator card["left"], :>=, 0, "the card is clipped on the left"
      assert_operator card["right"], :<=, card["vw"], "the card is clipped on the right"
    ensure
      FileUtils.rm_f(Rails.root.join(probe_path(pager)))
    end

    test "#{pager}: the phone takes the live Verto on tap, and hands it back" do
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      serve_probe_copy(pager, origin, survey.publish_token)

      visit "#{origin}#{probe_url}"
      assert_selector "#demoMockup.is-live", wait: 15
      assert_selector "#phonePlayOverlay", visible: :visible

      find("#phonePlayOverlay").click
      assert_selector "#phoneMockup.is-live", wait: 15
      # ONE live frame at a time — the whole point (shared session token).
      assert_no_selector "#demoMockup.is-live"
      assert_no_selector "#demoMockup .screen-embed"

      # The phone frame runs the player's real phone layout, not a shrunken
      # desktop: 390 logical is under the 767px breakpoint.
      width = within_frame(find(".phone-screen-embed")) do
        page.evaluate_script("window.innerWidth")
      end
      assert_equal 390, width

      # Playable, not a picture: the deck is reachable inside the phone.
      within_frame(find(".phone-screen-embed")) do
        assert_selector "[data-card-type]", minimum: 1, wait: 10
      end

      # With the phone live, the laptop shows a "bring it back" scrim, which has
      # to sit on the screen glass and nowhere else. `.laptop-overlay` reaches
      # that position by overriding the `inset: 10px` it inherits from
      # `.device-overlay` — and `inset` is a shorthand for all four offsets, so
      # declaring it *after* left/top silently resets them to auto and the scrim
      # lands at its static position, hanging off the side of the laptop. That
      # shipped once.
      scrim = page.evaluate_script(<<~JS)
        (() => {
          const o = document.getElementById('laptopPlayOverlay');
          const m = document.getElementById('demoMockup');
          const r = o.getBoundingClientRect(), mr = m.getBoundingClientRect();
          return { dx: r.x - (mr.x + mr.width * 0.124),
                   dy: r.y - (mr.y + mr.height * 0.031),
                   dw: r.width - mr.width * 0.7515,
                   dh: r.height - mr.height * 0.69 };
        })()
      JS
      assert_in_delta 0, scrim["dx"], 1.5, "the scrim is offset horizontally from the laptop's screen"
      assert_in_delta 0, scrim["dy"], 1.5, "the scrim is offset vertically from the laptop's screen"
      assert_in_delta 0, scrim["dw"], 1.5, "the scrim isn't the width of the laptop's screen"
      assert_in_delta 0, scrim["dh"], 1.5, "the scrim isn't the height of the laptop's screen"

      find("#laptopPlayOverlay").click
      assert_selector "#demoMockup.is-live", wait: 15
      assert_no_selector "#phoneMockup.is-live"
      assert_no_selector ".phone-screen-embed"
    ensure
      FileUtils.rm_f(Rails.root.join(probe_path(pager)))
    end

    test "#{pager}: nothing spills sideways on a phone" do
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      serve_probe_copy(pager, origin, survey.publish_token)

      # A narrow *window* doesn't measure a phone: Chromium clamps its window to
      # roughly 500px wide, so the layout quietly stays desktop-ish. Device
      # metrics are the only honest way to get 390 here.
      page.driver.browser.page.command("Emulation.setDeviceMetricsOverride",
                                       width: 390, height: 900, deviceScaleFactor: 1, mobile: true)
      begin
        visit "#{origin}#{probe_url}"
        assert_selector "#demoMockup", wait: 15

        widths = page.evaluate_script(<<~JS)
          ({ scroll: document.documentElement.scrollWidth,
             client: document.documentElement.clientWidth })
        JS
        assert_equal 390, widths["client"], "device emulation didn't take"
        assert_operator widths["scroll"], :<=, widths["client"] + 1,
          "the page scrolls sideways on a phone — something is wider than the viewport " \
          "and can't shrink (a grid or flex item defaulting to min-width: auto will do it)"

        # The screenshots are deliberately wider than the phone, but they have to
        # pan inside their own frame rather than drag the page with them.
        panned = page.evaluate_script(<<~JS)
          [...document.querySelectorAll('.shot-pan')].map(e => ({
            clips: e.scrollWidth > e.clientWidth,
            overflow: getComputedStyle(e).overflowX,
          }))
        JS
        panned.each do |p|
          assert_equal "auto", p["overflow"], "a wide screenshot isn't in a scrollable frame"
        end
      ensure
        page.driver.browser.page.command("Emulation.clearDeviceMetricsOverride")
      end
    ensure
      FileUtils.rm_f(Rails.root.join(probe_path(pager)))
    end

    test "#{pager}: the frame fills the screen area exactly, without spilling onto the bezel" do
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      serve_probe_copy(pager, origin, survey.publish_token)

      visit "#{origin}#{probe_url}"
      assert_selector "#demoMockup.is-live", wait: 15

      box = page.evaluate_script(<<~JS)
        (() => {
          const m = document.getElementById('demoMockup');
          const f = m.querySelector('.screen-embed');
          const fr = f.getBoundingClientRect(), mr = m.getBoundingClientRect();
          return { frameW: fr.width, frameH: fr.height,
                   screenW: mr.width * 0.7515, screenH: mr.height * 0.69 };
        })()
      JS

      # Within a pixel: the scaled frame should be the screen glass, no more.
      assert_in_delta box["screenW"], box["frameW"], 1.5, "the frame is wider than the laptop's screen"
      assert_in_delta box["screenH"], box["frameH"], 1.5, "the frame is taller than the laptop's screen"
    ensure
      FileUtils.rm_f(Rails.root.join(probe_path(pager)))
    end
  end
end
