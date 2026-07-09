require "test_helper"

# Region data now comes from exactly one source: the "Where do you live?"
# demographic question (input: "location"), universal on every Verto — no
# separate ask_region opt-in and no creator-minted region links (both
# retired). See PlayerController#sync_region_from_answers!.
class LocationDemographicTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Do you like sport?", "options" => [ "Yes", "No" ] },
    { "type" => "open_ended", "input" => "location", "text" => "Where do you live?", "demographic" => true }
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

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  test "the demographic location card renders the search widget, not free text" do
    org = create_org_and_sign_in("render")
    s   = create_survey(org)

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_match "Search for your city or region", response.body
    assert_match "Search by OpenStreetMap", response.body
  end

  test "a resolved CC|Label answer populates region_country/region_label" do
    org = create_org_and_sign_in("resolve")
    s   = create_survey(org)

    json_post submit_survey_path(s.publish_token),
              { session_token: "loc-#{SecureRandom.hex(4)}",
                answers: {
                  "1" => { "type" => "yes_no", "value" => "Yes" },
                  "2" => { "type" => "open_ended", "value" => "US|Austin, Texas" }
                } }
    assert_response :success
    resp = s.responses.reload.last
    assert_equal "US", resp.region_country
    assert_equal "Austin, Texas", resp.region_label
  end

  test "an invalid country code leaves the response untagged" do
    org = create_org_and_sign_in("invalid")
    s   = create_survey(org)

    json_post submit_survey_path(s.publish_token),
              { session_token: "loc-#{SecureRandom.hex(4)}",
                answers: {
                  "1" => { "type" => "yes_no", "value" => "Yes" },
                  "2" => { "type" => "open_ended", "value" => "ZZ|Atlantis" }
                } }
    resp = s.responses.reload.last
    assert_nil resp.region_country
    assert_nil resp.region_label
  end

  test "leaving the location question unanswered leaves the response untagged" do
    org = create_org_and_sign_in("blank")
    s   = create_survey(org)

    json_post submit_survey_path(s.publish_token),
              { session_token: "loc-#{SecureRandom.hex(4)}",
                answers: { "1" => { "type" => "yes_no", "value" => "Yes" } } }
    resp = s.responses.reload.last
    assert_nil resp.region_country
  end

  test "the regions endpoint is always available and applies small-cell suppression" do
    org = create_org_and_sign_in("agg")
    s   = create_survey(org)

    5.times do |i|
      s.responses.create!(session_token: "gb-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          region_country: "GB", region_label: "Yorkshire",
                          answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end
    2.times do |i|
      s.responses.create!(session_token: "fr-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          region_country: "FR", region_label: nil,
                          answers: { "1" => { "type" => "yes_no", "value" => "No" } })
    end
    s.responses.create!(session_token: "untagged-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "No" } })

    get player_regions_path(s.publish_token)
    assert_response :success
    data = JSON.parse(response.body)
    assert data["ok"]
    assert_equal 7, data["total_tagged"]
    # FR (2 responders) is below Response::MIN_REGION_SAMPLE_SIZE — suppressed.
    assert_equal [ "GB" ], data["regions"].map { |r| r["country"] }
    top = data["regions"].first
    assert_equal [ "GB", "Yorkshire", 5 ], [ top["country"], top["label"], top["responders"] ]
  end

  test "the regions endpoint counts partial responders, not only completers" do
    org = create_org_and_sign_in("partial-region")
    s   = create_survey(org)

    # 5 region-tagged responders who answered but never submitted (started)
    5.times do |i|
      s.responses.create!(session_token: "gb-started-#{i}-#{SecureRandom.hex(3)}", status: "started",
                          region_country: "GB", region_label: "Yorkshire",
                          answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end

    get player_regions_path(s.publish_token)
    data = JSON.parse(response.body)
    assert data["ok"]
    assert_equal [ "GB" ], data["regions"].map { |r| r["country"] }
    assert_equal 5, data["regions"].first["responders"]
  end

  test "creator results show region segments and the world map once responses accumulate" do
    org = create_org_and_sign_in("results")
    s   = create_survey(org)
    5.times do |i|
      s.responses.create!(session_token: "r-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          region_country: "GB", region_label: "Yorkshire",
                          answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end

    get survey_results_path(s)
    assert_response :success
    assert_match 'id="world-map"', response.body
    assert_match "United Kingdom · Yorkshire", response.body
  end
end
