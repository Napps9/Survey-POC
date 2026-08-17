require "test_helper"

# The per-Verto PWA install manifest — see PlayerController#manifest. No
# worker behaviour depends on this (see the action's own comment for why it
# needs no CACHE_VERSION bump), so this only has to prove the JSON shape and
# the same token/publish boundary the rest of /play already enforces.
class PlayManifestTest < ActionDispatch::IntegrationTest
  def published_survey(**attrs)
    org = Organisation.create!(name: "Acme", slug: "pm-#{SecureRandom.hex(2)}")
    org.surveys.create!(title: "Sports", theme: "Sports", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ],
                        cards: [ { "type" => "welcome_card", "title" => "hi" } ],
                        publish_token: SecureRandom.hex(8), published_at: Time.current, **attrs)
  end

  test "returns an installable manifest scoped to /play/ with a token-correct start_url" do
    survey = published_survey

    get play_manifest_path(survey.publish_token)
    assert_response :success
    assert_equal "application/json", response.media_type

    body = JSON.parse(response.body)
    assert_equal "Sports", body["name"]
    assert_equal "/play/#{survey.publish_token}", body["start_url"]
    assert_equal "/play/", body["scope"]
    assert_equal "standalone", body["display"]
    assert_equal "/icon.png", body["icons"].first["src"]
    assert body["icons"].any? { |i| i["purpose"] == "maskable" }
  end

  test "the theme colour follows the Verto's brand palette" do
    survey = published_survey(brand_palette: { "bg" => "#112233" })
    get play_manifest_path(survey.publish_token)
    assert_equal "#112233", JSON.parse(response.body)["theme_color"]
  end

  test "falls back to the survey title when there is no theme" do
    survey = published_survey
    survey.update_columns(theme: "")
    get play_manifest_path(survey.publish_token)
    assert_equal "Sports", JSON.parse(response.body)["name"] # theme and title are both "Sports" here
  end

  test "an unknown token 404s" do
    get play_manifest_path("no-such-token")
    assert_response :not_found
  end

  test "an unpublished Verto 404s — no manifest for a link nobody can play yet" do
    survey = published_survey
    survey.update!(unpublished_at: Time.current)
    get play_manifest_path(survey.publish_token)
    assert_response :not_found
  end

  test "a deleted Verto 404s" do
    survey = published_survey
    survey.update_columns(deleted_at: Time.current)
    get play_manifest_path(survey.publish_token)
    assert_response :not_found
  end

  test "a named share link's slug resolves the same manifest, start_url and all" do
    survey = published_survey
    link = survey.survey_links.create!(slug: "custom-#{SecureRandom.hex(3)}", name: "N")

    get play_manifest_path(link.slug)
    assert_response :success
    assert_equal "/play/#{link.slug}", JSON.parse(response.body)["start_url"]
  end
end
