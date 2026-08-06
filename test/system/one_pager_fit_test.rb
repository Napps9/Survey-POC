require "application_system_test_case"

# The laptop mockup in public/vertonow.html hands the embedded player a fixed
# logical viewport and scales it into the screen area. The player's card is a
# fixed 850x680 box (.split-card) that nothing shrinks, so a viewport shorter
# than that clips it — centred, so the top goes first, which is exactly how this
# shipped once: 1000x567 cut 82px off the top of every card.
#
# Introspecting the frame needs same origin, so this visits a copy of the page
# served by the app. The file:// half of the contract lives in
# one_pager_embed_test.rb, where the frame is cross-origin and can't be measured.
class OnePagerFitTest < ApplicationSystemTestCase
  PROBE = "public/__fit_probe.html".freeze

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

  # The shipped page, pointed at this test's server instead of production.
  def serve_probe_copy(origin, token)
    html = Rails.root.join("public/vertonow.html").read
      .sub('const DEMO_ORIGIN = "https://app.playverto.com";', %(const DEMO_ORIGIN = "#{origin}";))
      .sub('const DEMO_PATH   = "/play/KcwFrqUdXqFCfcmKapJH_JrO";', %(const DEMO_PATH   = "/play/#{token}";))
    Rails.root.join(PROBE).write(html)
  end

  test "the embedded Verto is never clipped by the laptop screen" do
    survey = published_survey
    origin = Capybara.current_session.server.base_url
    serve_probe_copy(origin, survey.publish_token)

    visit "#{origin}/__fit_probe.html"
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
    FileUtils.rm_f(Rails.root.join(PROBE))
  end

  test "the frame fills the screen area exactly, without spilling onto the bezel" do
    survey = published_survey
    origin = Capybara.current_session.server.base_url
    serve_probe_copy(origin, survey.publish_token)

    visit "#{origin}/__fit_probe.html"
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
    FileUtils.rm_f(Rails.root.join(PROBE))
  end
end
