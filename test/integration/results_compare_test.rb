require "test_helper"

class ResultsCompareTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Do you like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  def create_org_and_sign_in(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def create_survey(org)
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def seed_region(survey, country, label, count)
    count.times do |i|
      survey.responses.create!(session_token: "#{country}-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                               region_country: country, region_label: label,
                               answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end
  end

  test "includes resolved lat/lng and country bounds for a region segment" do
    org = create_org_and_sign_in("geo")
    s   = create_survey(org)
    seed_region(s, "US", "Austin, Texas", 5)

    stub_method(NominatimGeocodeClient, :coordinates_for, ->(**_kw) { { lat: 30.27, lng: -97.74 } }) do
      get survey_results_compare_path(s)
    end
    assert_response :success

    data = JSON.parse(response.body)
    assert data["ok"]
    region = data["segments"].find { |seg| seg["label"].include?("Austin, Texas") }
    assert_equal 30.27, region["lat"]
    assert_equal(-97.74, region["lng"])
    assert_equal [ 25.0, 49.5, -125.0, -66.96 ], data["bounds"]["us"]
  end

  test "omits lat/lng when Nominatim can't resolve the tag, without breaking the response" do
    org = create_org_and_sign_in("geo-miss")
    s   = create_survey(org)
    seed_region(s, "ZA", "Nowhereville", 5)

    stub_method(NominatimGeocodeClient, :coordinates_for, ->(**_kw) { nil }) do
      get survey_results_compare_path(s)
    end
    assert_response :success

    data = JSON.parse(response.body)
    region = data["segments"].find { |seg| seg["label"].include?("Nowhereville") }
    refute region.key?("lat")
    refute region.key?("lng")
  end

  test "the overall segment is never geocoded" do
    org = create_org_and_sign_in("geo-overall")
    s   = create_survey(org)
    s.responses.create!(session_token: "plain-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })

    stub_method(NominatimGeocodeClient, :coordinates_for, ->(**_kw) { raise "should not geocode Overall" }) do
      get survey_results_compare_path(s)
    end
    assert_response :success
    overall = JSON.parse(response.body)["segments"].find { |seg| seg["id"] == "overall" }
    refute overall.key?("lat")
  end
end
