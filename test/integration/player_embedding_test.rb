require "test_helper"

# See PlayerController#allow_embedding. A Verto is meant to be embeddable — in a
# partner's page, and in the one-pager (public/vertonow.html) that gets sent
# around as an HTML file. Everything else in the app stays same-origin only.
class PlayerEmbeddingTest < ActionDispatch::IntegrationTest
  def survey_with(**attrs)
    org = Organisation.create!(name: "Embed Co", slug: "embed-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      **attrs
    )
  end

  def frame_ancestors
    csp = response.headers["Content-Security-Policy"].to_s
    csp.split(";").map(&:strip).find { |d| d.start_with?("frame-ancestors") }
  end

  def with_frame_ancestors(value)
    was = ENV["PLAYER_FRAME_ANCESTORS"]
    ENV["PLAYER_FRAME_ANCESTORS"] = value
    yield
  ensure
    ENV["PLAYER_FRAME_ANCESTORS"] = was
  end

  test "the player may be framed by the app and by a locally-opened file" do
    get play_survey_path(survey_with(publish_token: SecureRandom.hex(8)).publish_token)
    assert_response :success

    # `file:` is what lets a downloaded copy of the one-pager frame it: a local
    # page's origin is opaque, and Chrome matches it against neither 'self' nor
    # even '*'. Verified against a real browser before it was written down.
    assert_equal "frame-ancestors 'self' file:", frame_ancestors
    assert_nil response.headers["X-Frame-Options"],
      "SAMEORIGIN would block a file:// parent on its own, whatever the CSP says"
  end

  test "Test Mode is embeddable on the same terms" do
    survey = survey_with(publish_token: SecureRandom.hex(8), test_token: SecureRandom.hex(8))

    get test_survey_path(survey.test_token)
    assert_response :success
    assert_equal "frame-ancestors 'self' file:", frame_ancestors
  end

  # A Verto embedded in a page on another domain — the marketing site, a
  # partner's page — needs that domain named. It's a deploy setting rather than
  # a constant because the list belongs to whoever owns the domains, and
  # `frame-ancestors` is checked against every ancestor rather than only the
  # immediate parent, so nesting doesn't get you out of naming them.
  test "PLAYER_FRAME_ANCESTORS adds sites without displacing the defaults" do
    with_frame_ancestors("https://www.playverto.com https://playverto.webflow.io") do
      get play_survey_path(survey_with(publish_token: SecureRandom.hex(8)).publish_token)
      assert_response :success
      assert_equal "frame-ancestors 'self' file: https://www.playverto.com https://playverto.webflow.io",
        frame_ancestors
    end
  end

  test "PLAYER_FRAME_ANCESTORS accepts commas, and drops sources a CSP can't use" do
    # A bare host is silently inert in a source list and `*` would let any site
    # on the internet frame a Verto — the one thing this directive prevents. Both
    # are likelier as a typo than as an intention, so neither survives.
    with_frame_ancestors("playverto.com, *, https://ok.example.com , javascript:alert(1)") do
      get play_survey_path(survey_with(publish_token: SecureRandom.hex(8)).publish_token)
      assert_equal "frame-ancestors 'self' file: https://ok.example.com", frame_ancestors
    end
  end

  test "the rest of the app is still same-origin only" do
    get new_session_path
    assert_response :success

    assert_equal "frame-ancestors 'self'", frame_ancestors,
      "only the player opted into embedding — the studio must not follow it"
    assert_equal "SAMEORIGIN", response.headers["X-Frame-Options"]
  end

  test "the player keeps the rest of the app-wide policy" do
    get play_survey_path(survey_with(publish_token: SecureRandom.hex(8)).publish_token)
    assert_response :success

    # Only frame-ancestors is rewritten; script-src, img-src and friends must
    # survive, or embedding would quietly strip the player's own protections.
    csp = response.headers["Content-Security-Policy"].to_s
    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "https://images.pexels.com"
  end
end
