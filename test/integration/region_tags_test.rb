require "test_helper"

class RegionTagsTest < ActionDispatch::IntegrationTest
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

  def create_survey(org, published: true)
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS,
                        publish_token: published ? SecureRandom.urlsafe_base64(18) : nil,
                        published_at: published ? Time.current : nil)
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  test "creator adds and removes a region link in the editor" do
    org = create_org_and_sign_in("editor")
    s   = create_survey(org)

    post survey_region_links_path(s), params: { country_code: "GB", label: "Yorkshire" }
    follow_redirect!
    assert_response :success
    link = s.survey_region_links.reload.first
    assert_equal [ "GB", "Yorkshire" ], [ link.country_code, link.label ]
    assert_match play_survey_url(link.token), response.body
    assert_match "United Kingdom · Yorkshire", response.body

    delete survey_region_link_path(s, link.id)
    assert_equal 0, s.survey_region_links.reload.count
  end

  test "invalid country codes are rejected" do
    org = create_org_and_sign_in("invalid")
    s   = create_survey(org)
    post survey_region_links_path(s), params: { country_code: "ZZ", label: "" }
    assert_equal 0, s.survey_region_links.reload.count
  end

  test "region URL shows the consent notice and tags the response" do
    org  = create_org_and_sign_in("tagging")
    s    = create_survey(org)
    link = s.survey_region_links.create!(country_code: "GB", label: "Yorkshire")

    get play_survey_path(link.token)
    assert_response :success
    assert_match "collects regional data", response.body
    assert_match "United Kingdom · Yorkshire", response.body

    json_post submit_survey_path(link.token),
              { session_token: "rt-#{SecureRandom.hex(4)}", answers: { "1" => { "type" => "yes_no", "value" => "Yes" } } }
    assert_response :success
    resp = s.responses.reload.last
    assert_equal [ "GB", "Yorkshire", link.id ], [ resp.region_country, resp.region_label, resp.survey_region_link_id ]
  end

  test "opt-out clears a link-borne region" do
    org  = create_org_and_sign_in("optout")
    s    = create_survey(org)
    link = s.survey_region_links.create!(country_code: "GB", label: nil)

    json_post submit_survey_path(link.token),
              { session_token: "ro-#{SecureRandom.hex(4)}", region_opt_out: true,
                answers: { "1" => { "type" => "yes_no", "value" => "No" } } }
    assert_response :success
    resp = s.responses.reload.last
    assert_nil resp.region_country
    assert_nil resp.survey_region_link_id
  end

  test "base link offers the picker and accepts only the Verto's own regions" do
    org = create_org_and_sign_in("picker")
    s   = create_survey(org)
    s.survey_region_links.create!(country_code: "GB", label: "Yorkshire")

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_match "Prefer not to say", response.body
    assert_match "GB|Yorkshire", response.body

    # Self-picked region matching a tag (case-insensitive country) is stored…
    json_post submit_survey_path(s.publish_token),
              { session_token: "rp-#{SecureRandom.hex(4)}", region_country: "gb", region_label: "Yorkshire",
                answers: { "1" => { "type" => "yes_no", "value" => "Yes" } } }
    assert_equal "GB", s.responses.reload.last.region_country

    # …but junk that matches no tag leaves the response untagged.
    json_post submit_survey_path(s.publish_token),
              { session_token: "rj-#{SecureRandom.hex(4)}", region_country: "GB", region_label: "Atlantis",
                answers: { "1" => { "type" => "yes_no", "value" => "Yes" } } }
    assert_nil s.responses.reload.last.region_country
  end

  test "regions endpoint aggregates per region, gated on region tags" do
    org  = create_org_and_sign_in("agg")
    s    = create_survey(org)
    gb   = s.survey_region_links.create!(country_code: "GB", label: "Yorkshire")
    fr   = s.survey_region_links.create!(country_code: "FR", label: nil)

    # Both regions meet MIN_REGION_SAMPLE_SIZE so neither is suppressed below.
    5.times do |i|
      s.responses.create!(session_token: "gb-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          survey_region_link: gb, region_country: "GB", region_label: "Yorkshire",
                          answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end
    5.times do |i|
      s.responses.create!(session_token: "fr-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          survey_region_link: fr, region_country: "FR", region_label: nil,
                          answers: { "1" => { "type" => "yes_no", "value" => "No" } })
    end
    s.responses.create!(session_token: "untagged-#{SecureRandom.hex(3)}", status: "completed",
                        answers: { "1" => { "type" => "yes_no", "value" => "No" } })

    get player_regions_path(s.publish_token)
    assert_response :success
    data = JSON.parse(response.body)
    assert data["ok"]
    assert_equal 10, data["total_tagged"]
    assert_equal 2, data["regions"].size
    top = data["regions"].first
    assert_equal [ "GB", "Yorkshire", 5 ], [ top["country"], top["label"], top["responders"] ]
    yes_no = top["results"].find { |r| r["type"] == "yes_no" }
    assert_equal({ "Yes" => 5 }, yes_no["counts"])

    bare = create_survey(create_org_and_sign_in("agg2"))
    get player_regions_path(bare.publish_token)
    assert_response :forbidden
  end

  test "a region below the minimum sample size is suppressed from the map/list" do
    org = create_org_and_sign_in("smallcell")
    s   = create_survey(org)
    gb  = s.survey_region_links.create!(country_code: "GB", label: "Yorkshire")
    de  = s.survey_region_links.create!(country_code: "DE", label: nil)

    5.times do |i|
      s.responses.create!(session_token: "gb-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          survey_region_link: gb, region_country: "GB", region_label: "Yorkshire",
                          answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end
    # Below Response::MIN_REGION_SAMPLE_SIZE — must not appear anywhere.
    2.times do |i|
      s.responses.create!(session_token: "de-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          survey_region_link: de, region_country: "DE", region_label: nil,
                          answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end

    get player_regions_path(s.publish_token)
    assert_response :success
    data = JSON.parse(response.body)
    assert_equal 7, data["total_tagged"] # raw count is unaffected — only the breakdown is suppressed
    assert_equal [ "GB" ], data["regions"].map { |r| r["country"] }

    get survey_results_path(s)
    assert_response :success
    assert_match "United Kingdom · Yorkshire", response.body
    refute_match "Germany", response.body
  end

  test "creation wizard region tags are minted with the new Verto" do
    org  = create_org_and_sign_in("wizard")
    fake = Object.new
    def fake.call(**)
      { "title" => "T", "description" => "d", "theme" => "T",
        "audience_age" => "a", "key_insight" => "k", "cards" => CARDS.map(&:dup) }
    end

    # minitest 6 ships without minitest/mock, so stub SurveyGenerator.new by hand.
    SurveyGenerator.define_singleton_method(:new) { |*| fake }
    begin
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0",
        region_tags: [
          { country_code: "GB", label: "Yorkshire" },
          { country_code: "GB", label: "Yorkshire" }, # duplicate — skipped
          { country_code: "ZZ", label: "" },          # invalid — skipped
          { country_code: "FR", label: "" }
        ]
      }
    ensure
      SurveyGenerator.singleton_class.remove_method(:new)
    end

    survey = org.surveys.order(:id).last
    assert_redirected_to survey_path(survey)
    tags = survey.survey_region_links.map { |l| [ l.country_code, l.label ] }.sort_by(&:first)
    assert_equal [ [ "FR", nil ], [ "GB", "Yorkshire" ] ], tags
    assert survey.survey_region_links.all? { |l| l.token.present? }
  end

  test "creator results show region segments and the world map" do
    org  = create_org_and_sign_in("results")
    s    = create_survey(org)
    link = s.survey_region_links.create!(country_code: "GB", label: "Yorkshire")
    # 5 responses to clear Response::MIN_REGION_SAMPLE_SIZE's suppression floor.
    5.times do |i|
      s.responses.create!(session_token: "r-#{i}-#{SecureRandom.hex(3)}", status: "completed",
                          survey_region_link: link, region_country: "GB", region_label: "Yorkshire",
                          answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })
    end

    get survey_results_path(s)
    assert_response :success
    assert_match 'id="world-map"', response.body
    assert_match "United Kingdom · Yorkshire", response.body

    segment_id = "region_#{Digest::MD5.hexdigest('GB|Yorkshire').first(10)}"
    get survey_results_path(s, segment: segment_id)
    assert_response :success
    assert_match "of 5 overall", response.body
  end

  test "ask-players mode stores any valid self-declared region" do
    org = create_org_and_sign_in("askmode")
    s   = create_survey(org)
    s.update!(ask_region: true)

    get play_survey_path(s.publish_token)
    assert_response :success
    # The satnav-style location search replaces the old country-select +
    # free-text area — see NominatimClient / location_search_controller.js.
    assert_match "Search for your city or region", response.body
    assert_match "Search by OpenStreetMap", response.body

    # The client resolves a search pick to country_code + label before
    # submitting — this simulates that resolved payload directly.
    5.times do |i|
      json_post submit_survey_path(s.publish_token),
                { session_token: "ask-#{i}-#{SecureRandom.hex(4)}", region_country: "ke", region_label: "Nairobi West",
                  answers: { "1" => { "type" => "yes_no", "value" => "Yes" } } }
    end
    resp = s.responses.reload.last
    assert_equal [ "KE", "Nairobi West", nil ], [ resp.region_country, resp.region_label, resp.survey_region_link_id ]

    # invalid country is rejected even in ask mode
    json_post submit_survey_path(s.publish_token),
              { session_token: "askbad-#{SecureRandom.hex(4)}", region_country: "ZZ", region_label: "Atlantis",
                answers: { "1" => { "type" => "yes_no", "value" => "No" } } }
    assert_nil s.responses.reload.last.region_country

    # self-declared regions surface in results segments and the map
    get survey_results_path(s)
    assert_match "Kenya · Nairobi West", response.body
    assert_match 'id="world-map"', response.body
  end

  test "compare promise shows on the welcome card when comparison is on" do
    org = create_org_and_sign_in("promise")
    s   = create_survey(org)
    s.update!(show_results_comparison: true)

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_match "welcome-intake-compare", response.body
    assert_match "Finish to see how your answers compare", response.body
  end

  test "the compare promise is editable, and the top banners are gone" do
    org = create_org_and_sign_in("editnote")
    s   = create_survey(org)
    s.survey_region_links.create!(country_code: "GB", label: "Yorkshire")
    s.update!(show_results_comparison: true)

    post survey_settings_path(s), params: { show_results_comparison: "1", compare_note: "Stick around for the big reveal!" }
    assert_redirected_to survey_path(s)
    assert_equal "Stick around for the big reveal!", s.reload.compare_note

    get play_survey_path(s.publish_token)
    assert_response :success
    # the custom promise + region picker render on the welcome card…
    assert_match "Stick around for the big reveal!", response.body
    assert_match "welcome-intake", response.body
    # …and no longer as top banners
    refute_match "Regional-data heads-up", response.body
  end
end
