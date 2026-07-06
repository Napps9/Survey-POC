require "test_helper"

class LocationSearchTest < ActionDispatch::IntegrationTest
  def published_survey
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ],
                        cards: [ { "type" => "welcome_card", "title" => "hi" } ],
                        ask_region: true,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  RESULT = { display_name: "Austin, Texas, United States", city: "Austin", region: "Texas",
             country: "United States", country_code: "US" }.freeze

  test "returns the resolved country_code + label, built from city/region only" do
    s = published_survey
    stub_method(NominatimClient, :search, ->(**_kw) { [ RESULT ] }) do
      get player_location_search_path(s.publish_token), params: { q: "Austin" }
    end
    assert_response :success
    data = JSON.parse(response.body)
    assert data["ok"]
    assert_equal 1, data["results"].size
    r = data["results"].first
    assert_equal "US", r["country_code"]
    assert_equal "Austin, Texas", r["label"]
    assert_equal "Austin, Texas, United States", r["display_name"]
  end

  test "404s for an unknown token" do
    stub_method(NominatimClient, :search, ->(**_kw) { [] }) do
      get player_location_search_path("does-not-exist"), params: { q: "Austin" }
    end
    assert_response :not_found
  end

  test "surfaces an empty result set gracefully" do
    s = published_survey
    stub_method(NominatimClient, :search, ->(**_kw) { [] }) do
      get player_location_search_path(s.publish_token), params: { q: "zzz" }
    end
    assert_response :success
    assert_equal [], JSON.parse(response.body)["results"]
  end
end
