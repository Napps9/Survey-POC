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

  # The two pages moved the live Verto apart. vertonow taps whichever device
  # isn't holding it; verto-for-research shows one device at a time and picks
  # with a tab, because sharing the row cost the laptop a quarter of its width
  # and the Verto inside came out too small to read. The contract is identical
  # either way — one live frame, and the session moves across — so the
  # assertions stay shared and only the gesture is per page. Detected from the
  # page rather than keyed to its filename, so a third fork picks the right one.
  def move_demo_to(device)
    if has_selector?(".device-tab", wait: 0)
      find(".device-tab[data-device='#{device}']").click
    else
      find(device == "phone" ? "#phonePlayOverlay" : "#laptopPlayOverlay").click
    end
  end

  # With the phone live, a page that keeps both devices on screen shows a "bring
  # it back" scrim, which has to sit on the screen glass and nowhere else.
  # `.laptop-overlay` reaches that position by overriding the `inset: 10px` it
  # inherits from `.device-overlay` — and `inset` is a shorthand for all four
  # offsets, so declaring it *after* left/top silently resets them to auto and
  # the scrim lands at its static position, hanging off the side of the laptop.
  # That shipped once.
  def assert_scrim_covers_the_glass
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

    test "#{pager}: the live Verto moves to the phone and back, one frame at a time" do
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      serve_probe_copy(pager, origin, survey.publish_token)

      visit "#{origin}#{probe_url}"
      assert_selector "#demoMockup.is-live", wait: 15

      move_demo_to("phone")
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

      # Only where both devices stay on screen: a page that shows one at a time
      # has no laptop to put a scrim on.
      assert_scrim_covers_the_glass if has_selector?("#laptopPlayOverlay", visible: :visible, wait: 0)

      move_demo_to("laptop")
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
        # Waiting on the demo would be wrong here: verto-for-research hides its
        # whole Try it section below 860px, deliberately, so a phone doesn't
        # download a player it will never show. The benefits list is the
        # readiness signal both pages render at this width.
        assert_selector ".benefits li", minimum: 1, wait: 15

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

        # Whatever a page chooses to show on a phone, it must not download a
        # player it doesn't show — an iframe inside display:none still fetches
        # its src. The two pages differ here (verto-for-research hides its Try
        # it section entirely, vertonow keeps the player full-width), so this
        # pins the rule rather than either page's answer to it.
        demo = page.evaluate_script(<<~JS)
          (() => {
            const m = document.getElementById('demoMockup');
            return { shown: !!(m && m.getBoundingClientRect().height > 0),
                     iframe: !!document.querySelector('.screen-embed, .phone-screen-embed') };
          })()
        JS
        refute demo["iframe"] && !demo["shown"],
          "the demo is hidden at this width but its iframe was created anyway — that is a " \
          "whole player fetched over mobile data for something the reader never sees"
      ensure
        page.driver.browser.page.command("Emulation.clearDeviceMetricsOverride")
      end
    ensure
      FileUtils.rm_f(Rails.root.join(probe_path(pager)))
    end

    # The complaint that produced the tabs: sharing the row with the phone put
    # verto-for-research at 0.36, which renders a desktop layout's 16px body
    # text at about 7px on screen — reported as unreadable, and fairly.
    #
    # Three measured points set the floor. 0.362 was called unreadable; 0.428
    # is vertonow, which has shipped that way without complaint; 0.481 is
    # verto-for-research with the laptop alone on the stage. 0.40 sits between
    # the known-bad and the known-acceptable, so it catches a return to sharing
    # the row without being brittle about either page's exact layout.
    #
    # A floor on the scale rather than on any width, because scale is what a
    # reader actually experiences.
    test "#{pager}: the Verto is scaled large enough to read" do
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      serve_probe_copy(pager, origin, survey.publish_token)

      visit "#{origin}#{probe_url}"
      assert_selector "#demoMockup.is-live", wait: 15

      scale = page.evaluate_script(<<~JS)
        (() => {
          const m = document.getElementById('demoMockup');
          // 0.69 is the glass's share of the mockup's height; 780 is the
          // logical viewport the frame is given (EMBED_H).
          return (m.getBoundingClientRect().height * 0.69) / 780;
        })()
      JS
      assert_operator scale, :>=, 0.40,
        "the embedded Verto is scaled to #{scale.round(3)}; 0.362 was reported unreadable, so " \
        "anything approaching it means the laptop has lost width to something again"
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

  # verto-for-research only: vertonow deliberately keeps its player on a phone,
  # full-width, so this is one page's answer rather than a rule for both.
  #
  # The client proposal hides its Try it section on mobile — no laptop mockup,
  # no player fetched over mobile data. That was expressed as `max-width: 860px`
  # for a while, which quietly failed the moment anyone turned a phone sideways:
  # an iPhone 15 Pro Max in landscape is 932 CSS px, an iPad in landscape 1024,
  # so the readers the rule existed to spare were exactly the ones getting the
  # demo. Reported from the field on 2026-09-02 — "people on mobile are getting
  # demos and they shouldn't be" — and invisible to anyone testing in portrait.
  #
  # So the gate is `pointer: coarse`, and this test emulates touch rather than
  # only resizing: device metrics with `mobile: true` do NOT by themselves make
  # that media query match, which would make a width-only regression pass here.
  TOUCH_SIZES = [
    [ 390, 844, "phone portrait" ],
    [ 932, 430, "phone landscape" ],
    [ 1024, 768, "tablet landscape" ],
    [ 1366, 1024, "large tablet landscape" ]
  ].freeze

  TOUCH_SIZES.each do |width, height, label|
    test "verto-for-research: no demo reaches a touch device (#{label}, #{width}px)" do
      pager = "verto-for-research.html"
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      serve_probe_copy(pager, origin, survey.publish_token)

      cdp = page.driver.browser.page
      cdp.command("Emulation.setDeviceMetricsOverride",
                  width: width, height: height, deviceScaleFactor: 1, mobile: true)
      cdp.command("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
      begin
        visit "#{origin}/__fit_probe_verto-for-research.html"
        assert_selector ".benefits li", minimum: 1, wait: 15

        state = page.evaluate_script(<<~JS)
          (() => {
            const t = document.getElementById('try');
            const navTry = document.querySelector('.nav-link[href="#try"]');
            const shown = (el) => !!(el && el.getBoundingClientRect().height > 0);
            return { coarse: matchMedia('(pointer: coarse)').matches,
                     try: shown(t), navTry: shown(navTry),
                     iframe: !!document.querySelector('.screen-embed, .phone-screen-embed'),
                     ctas: [...document.querySelectorAll('.hero-ctas a')]
                             .filter(shown).map(a => a.getAttribute('href')) };
          })()
        JS

        assert state["coarse"],
          "touch emulation didn't take, so this ran as a desktop and proves nothing"
        refute state["try"], "the Try it section is on screen for a touch device"
        refute state["iframe"],
          "a player iframe was created on a touch device — that is the whole page's " \
          "worth of player fetched over mobile data for something nobody can see"

        # The section and everything pointing at it travel together: a surviving
        # link to a display:none section scrolls nowhere, which is how the nav
        # entry outlived its section between 860px and the tablet widths.
        refute state["navTry"], "the nav still links to #try, which is hidden here"
        assert_equal [], state["ctas"].grep(/\A#try\z/),
          "the hero button still scrolls to #try, which is hidden here"
        assert_equal 1, state["ctas"].length, "expected exactly one hero CTA to be visible"
        assert_match %r{\Ahttps://app\.playverto\.com/play/}, state["ctas"].first,
          "a touch reader's only CTA must open the real Verto, since there is none in the page"
      ensure
        cdp.command("Emulation.clearDeviceMetricsOverride")
        cdp.command("Emulation.setTouchEmulationEnabled", enabled: false)
      end
    ensure
      FileUtils.rm_f(Rails.root.join(probe_path("verto-for-research.html")))
    end
  end
end
