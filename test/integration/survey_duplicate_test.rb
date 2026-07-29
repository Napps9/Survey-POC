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
    # Card content is copied verbatim; only the stable cids are freshly minted.
    assert_equal CARDS, copy.cards.map { |c| c.except("cid") }
    assert(copy.cards.all? { |c| c["cid"].to_s.start_with?("c_") })
  end

  test "duplicating regenerates cids and remaps branching routes to the copy's cards" do
    cards = [
      { "type" => "multiple_choice", "cid" => "c_src_a", "text" => "Hub?", "options" => %w[UK US],
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_src_b" } }
        ], "default" => { "card" => "c_src_b" } } },
      { "type" => "open_ended", "cid" => "c_src_b", "text" => "UK page" }
    ]
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], logic: true, cards: cards)

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    assert copy.logic?
    src_cids  = original.cards.map { |c| c["cid"] }
    copy_cids = copy.cards.map { |c| c["cid"] }
    assert_empty(copy_cids & src_cids, "copy must not reuse any source cid")

    # The route now points at the COPY's second card, not the original's.
    route_target = copy.cards.first.dig("logic", "routes", 0, "to", "card")
    assert_equal copy.cards.second["cid"], route_target
    assert_equal copy.cards.second["cid"], copy.cards.first.dig("logic", "default", "card")
  end

  test "duplicating copies flows and remaps a flow's card exit to the copy's cids" do
    cards = [
      { "type" => "multiple_choice", "cid" => "c_hub", "text" => "Region?", "options" => %w[UK Other],
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_uk1" } }
        ] } },
      { "type" => "open_ended", "cid" => "c_uk1", "text" => "UK Q", "flow_id" => "f_uk", "next" => { "card" => "c_tail" } },
      { "type" => "open_ended", "cid" => "c_tail", "text" => "Tail" }
    ]
    flows = [ { "id" => "f_uk", "name" => "UK", "color" => "#8B85FF", "exit" => { "card" => "c_tail" } } ]
    original = @org.surveys.create!(title: "T", theme: "Theme", audience_age: "all", key_insight: "k",
                                     default_locale: "en", locales: [ "en" ], logic: true,
                                     cards: cards, flows: flows)

    post duplicate_survey_path(original)
    copy = @org.surveys.order(:id).last

    assert_equal 1, copy.flows_list.size
    flow = copy.flows_list.first
    assert_equal %w[f_uk UK], [ flow["id"], flow["name"] ], "flow identity copies verbatim (survey-scoped ids)"
    assert_equal "f_uk", copy.cards.second["flow_id"], "membership copies verbatim"
    # The exit points at the COPY's tail card, which has a fresh cid.
    assert_equal copy.cards.third["cid"], flow.dig("exit", "card")
    refute_equal "c_tail", flow.dig("exit", "card")
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
