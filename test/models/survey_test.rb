require "test_helper"

class SurveyTest < ActiveSupport::TestCase
  # ── sanitize_background_image ──────────────────────────────────────────────

  test "accepts an app-rooted asset image path" do
    path = "/assets/verto-library/backgrounds/landscape.jpg"
    assert_equal path, Survey.sanitize_background_image(path)
  end

  test "accepts a small base64 data-image URL" do
    url = "data:image/webp;base64,#{Base64.strict_encode64("small")}"
    assert_equal url, Survey.sanitize_background_image(url)
  end

  test "rejects an oversized base64 data-image URL" do
    blob = "A" * (Survey::MAX_BACKGROUND_DATA_URL_BYTES + 1)
    url  = "data:image/jpeg;base64,#{blob}"
    assert_nil Survey.sanitize_background_image(url)
  end

  test "rejects a non-image value" do
    assert_nil Survey.sanitize_background_image("https://evil.example/x.png")
    assert_nil Survey.sanitize_background_image("javascript:alert(1)")
  end

  test "treats blank as no background" do
    assert_nil Survey.sanitize_background_image("")
    assert_nil Survey.sanitize_background_image(nil)
    assert_nil Survey.sanitize_background_image("   ")
  end

  # ── sanitize_token_types ────────────────────────────────────────────────────

  test "keeps well-formed token type entries, trimmed" do
    types = Survey.sanitize_token_types([
      { "id" => "gold", "name" => "  Gold Coins  ", "icon" => "🪙" }
    ])
    assert_equal [ { "id" => "gold", "name" => "Gold Coins", "icon" => "🪙" } ], types
  end

  test "assigns a stable id and a fallback icon when missing" do
    types = Survey.sanitize_token_types([ { "name" => "Coal" } ])
    assert_equal 1, types.size
    assert types.first["id"].present?
    assert_equal "Coal", types.first["name"]
    assert_equal "⭐", types.first["icon"]
  end

  test "drops entries with no name" do
    types = Survey.sanitize_token_types([ { "id" => "x", "name" => "  " }, { "name" => "Gold" } ])
    assert_equal [ "Gold" ], types.map { |t| t["name"] }
  end

  test "caps the number of token types" do
    entries = (1..Survey::MAX_TOKEN_TYPES + 5).map { |i| { "name" => "Type #{i}" } }
    types = Survey.sanitize_token_types(entries)
    assert_equal Survey::MAX_TOKEN_TYPES, types.size
  end

  test "treats a non-array value as no token types" do
    assert_equal [], Survey.sanitize_token_types(nil)
    assert_equal [], Survey.sanitize_token_types("garbage")
  end

  # ── verto_builds ───────────────────────────────────────────────────────────

  # verto_builds.survey_id is a real FK, so without the nullify association a
  # survey a build points at cannot be destroyed at all — production hit this
  # when an import rebuilt an org whose placeholder Verto was wizard-built.
  test "destroying a survey nullifies its builds rather than raising" do
    org  = Organisation.create!(name: "Build Org", slug: "st-#{SecureRandom.hex(3)}")
    user = User.create!(name: "Builder", email_address: "st-#{SecureRandom.hex(3)}@test.com",
                        password: "verylongpassword")
    survey = org.surveys.create!(title: "Built", theme: "Climate Action", audience_age: "all",
                                 key_insight: "x", default_locale: "en", locales: [ "en" ], cards: [])
    build = org.verto_builds.create!(user: user, survey: survey, status: "succeeded", kind: "generate")

    survey.destroy!

    assert_nil build.reload.survey_id

    org.destroy!
    assert_not VertoBuild.exists?(build.id)
  end
end
