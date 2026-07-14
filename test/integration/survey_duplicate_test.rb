require "test_helper"

class SurveyDuplicateTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like it?", "options" => [ "Yes", "No" ] }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "dup-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "dup-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "duplicating a draft creates another draft with (Copy) appended" do
    draft = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))

    assert_difference -> { @org.surveys.count }, 1 do
      post duplicate_survey_path(draft)
    end

    copy = @org.surveys.order(:id).last
    assert_redirected_to survey_path(copy)
    assert_not copy.published?
    assert_equal "T (Copy)", copy.title
    assert_equal "Theme (Copy)", copy.theme
    assert_equal CARDS, copy.cards
  end

  test "duplicating a live Verto lands the copy in Drafts" do
    live = @org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                 publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post duplicate_survey_path(live)
    copy = @org.surveys.order(:id).last

    assert copy.id != live.id
    assert_nil copy.publish_token
    assert_nil copy.published_at
    assert_nil copy.slug
    assert_not copy.published?
  end

  test "the copy's cards are independent of the source's" do
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    copy.cards.first["title"] = "mutated"
    original.reload
    assert_equal "hi", original.cards.first["title"]
  end

  test "results-report columns are not copied" do
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                     results_summary: "some summary", results_summary_response_count: 5,
                                     results_report: "some report", results_report_response_count: 5,
                                     results_report_brief: '{"goal":"x"}')

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    assert_nil copy.results_summary
    assert_nil copy.results_summary_response_count
    assert_nil copy.results_report
    assert_nil copy.results_report_response_count
    assert_nil copy.results_report_brief
  end

  test "another org's survey is not reachable" do
    other = Organisation.create!(name: "X", slug: "dup2-#{SecureRandom.hex(2)}")
    s2 = other.surveys.create!(title: "S2", theme: "t", audience_age: "all",
                                key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
    post duplicate_survey_path(s2)
    assert_response :not_found
  end

  test "dashboard renders a Duplicate button for both drafts and live Vertos" do
    draft = @org.surveys.create!(title: "D", theme: "D", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])
    live  = @org.surveys.create!(title: "L", theme: "L", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [],
                                  publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get root_path
    assert_response :success
    assert_match duplicate_survey_path(draft), response.body
    assert_match duplicate_survey_path(live), response.body
  end
end
