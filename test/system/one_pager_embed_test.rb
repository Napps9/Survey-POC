require "application_system_test_case"

# public/vertonow.html is sent around as a downloaded HTML file, and its laptop
# mockup frames a live Verto. That only works because the player opts into
# being framed by `file:` as well as 'self' (PlayerController#allow_embedding) —
# a local page's origin is opaque, so Chrome matches it against neither 'self'
# nor even '*'. Nothing about that is visible from an integration test: it lives
# in the browser's framing rules, so it's pinned here instead.
class OnePagerEmbedTest < ApplicationSystemTestCase
  # A copy of the real page, pointed at this test's server instead of
  # production. Everything else — the boot handshake, the fallback, the sizing —
  # is the shipped code.
  def downloaded_copy_pointing_at(origin, token)
    html = Rails.root.join("public/vertonow.html").read
      .sub('const DEMO_ORIGIN = "https://app.playverto.com";', %(const DEMO_ORIGIN = "#{origin}";))
      .sub('const DEMO_PATH   = "/play/KcwFrqUdXqFCfcmKapJH_JrO";', %(const DEMO_PATH   = "/play/#{token}";))

    path = Rails.root.join("tmp/one_pager_embed_test.html")
    path.write(html)
    path
  end

  def published_survey
    org = Organisation.create!(name: "Embed Co", slug: "embed-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "Embedded demo", theme: "Embedded demo", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome to the demo" },
        { "type" => "multiple_choice", "text" => "Coffee or tea?", "options" => [ "Coffee", "Tea" ] }
      ],
      publish_token: SecureRandom.urlsafe_base64(18),
      published_at: Time.current
    )
  end

  test "a page opened from disk plays the real Verto in the laptop" do
    survey = published_survey
    origin = Capybara.current_session.server.base_url
    copy   = downloaded_copy_pointing_at(origin, survey.publish_token)

    visit "file://#{copy}"

    # is-live is only set once the embedded player has actually announced
    # itself — cross-origin, so it can't be faked by the frame merely existing.
    # If this fails, the file fell back to its own built-in demo.
    assert_selector "#demoMockup.is-live", wait: 15
    # …and the built-in demo stays out of the way while the real thing plays.
    assert_no_selector "#vertoDemo.is-on"

    # Not asserted from inside the frame: it's cross-origin here (file:// parent),
    # which is the very thing under test, and the driver can't step into it. The
    # is-live check above is the stronger signal anyway — it's set only when the
    # embedded player posts verto:ready, so it cannot pass unless the real player
    # booted in there.
    assert_equal "#{origin}/play/#{survey.publish_token}",
      find(".screen-embed", visible: :all)[:src]
  ensure
    FileUtils.rm_f(Rails.root.join("tmp/one_pager_embed_test.html"))
  end

  test "with the Verto unreachable it falls back to the built-in demo" do
    # Nothing listening on that port, so the frame can never boot.
    copy = downloaded_copy_pointing_at("http://127.0.0.1:1", "nope")

    visit "file://#{copy}"

    # An unreachable Verto must leave something playable behind, not an empty
    # laptop — that's the whole point of keeping the built-in deck around.
    assert_selector "#vertoDemo.is-on", wait: 20
    assert_no_selector "#demoMockup.is-live"
  ensure
    FileUtils.rm_f(Rails.root.join("tmp/one_pager_embed_test.html"))
  end
end
