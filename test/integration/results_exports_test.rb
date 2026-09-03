require "test_helper"

class ResultsExportsTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "ex-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ex-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ]
    )
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })
    sign_in(@user)
  end

  test "downloads the raw-responses CSV as an attachment" do
    get survey_results_export_path(@survey, kind: "responses")
    assert_response :success
    assert_match %r{text/csv}, response.media_type
    assert_match "attachment", response.headers["Content-Disposition"]
    assert_match "verto-#{@survey.id}-responses", response.headers["Content-Disposition"]
    assert_equal [ 0xEF, 0xBB, 0xBF ], response.body.bytes.first(3), "expected a UTF-8 BOM"
    assert_match "Response ID", response.body
    assert_match "Colour?", response.body
    assert_match "Blue", response.body
  end

  # The research-assistant case: several people administer one Verto through
  # their own custom links, and a batch has to be identifiable afterwards. The
  # stamp already existed; this is it reaching the CSV, and the link segment
  # scoping the export to that one batch.
  test "a response through a custom link exports its link name, and the link segment exports only that batch" do
    link = @survey.survey_links.create!(name: "RA Sam", slug: "ra-sam-#{SecureRandom.hex(2)}")
    post progress_survey_path(link.slug),
         params: { session_token: "via-link", answers: { "0" => { "type" => "multiple_choice", "value" => "Green" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    get survey_results_export_path(@survey, kind: "responses")
    rows = CSV.parse(response.body.delete_prefix("\xEF\xBB\xBF".b.force_encoding("UTF-8")))
    source = rows.first.index("Source")
    assert_equal [ "Direct link", "RA Sam" ].sort, rows.drop(1).map { |r| r[source] }.sort

    get survey_results_export_path(@survey, kind: "responses", segment: "link_#{link.id}")
    rows = CSV.parse(response.body.delete_prefix("\xEF\xBB\xBF".b.force_encoding("UTF-8")))
    assert_equal 1, rows.drop(1).size, "the link's segment exports that batch alone"
    assert_equal "RA Sam", rows.last[source]
  end

  test "downloads the aggregated summary CSV" do
    get survey_results_export_path(@survey, kind: "summary")
    assert_response :success
    assert_match "verto-#{@survey.id}-summary", response.headers["Content-Disposition"]
    assert_match "Answer option", response.body
    assert_match "Blue", response.body
  end

  test "cannot export another org's Verto" do
    other = User.create!(name: "Z", email_address: "z-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org2  = Organisation.create!(name: "O2", slug: "ex2-#{SecureRandom.hex(3)}")
    org2.memberships.create!(user: other, role: "admin")
    sign_in(other)

    get survey_results_export_path(@survey, kind: "responses")
    assert_response :not_found
  end

  test "results page shows the Download control, all four export links, and hides Google when unconfigured" do
    get survey_results_path(@survey)
    assert_response :success
    assert_match "⤓ Download", response.body
    assert_match "Raw responses (.csv)", response.body
    assert_match "Summary (.csv)", response.body
    assert_match "Raw responses (.xlsx)", response.body
    assert_match "Summary (.xlsx)", response.body
    assert_no_match(/Connect Google Sheets|Export to Google Sheets/, response.body)
  end

  test "downloads the raw-responses XLSX with the right content type and filename" do
    get survey_results_export_path(@survey, kind: "responses", format: "xlsx")
    assert_response :success
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", response.media_type
    assert_match "attachment", response.headers["Content-Disposition"]
    assert_match "verto-#{@survey.id}-responses", response.headers["Content-Disposition"]
    assert_match(/\.xlsx"?$/, response.headers["Content-Disposition"])
    assert response.body.start_with?("PK"), "expected a real zip/xlsx container, not an error page"
  end

  test "downloads the aggregated summary XLSX" do
    get survey_results_export_path(@survey, kind: "summary", format: "xlsx")
    assert_response :success
    assert_match "verto-#{@survey.id}-summary", response.headers["Content-Disposition"]
    assert response.body.start_with?("PK")
  end

  test "cannot export another org's Verto as XLSX either" do
    other = User.create!(name: "Z", email_address: "zx-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org2  = Organisation.create!(name: "O2", slug: "ex3-#{SecureRandom.hex(3)}")
    org2.memberships.create!(user: other, role: "admin")
    sign_in(other)

    get survey_results_export_path(@survey, kind: "responses", format: "xlsx")
    assert_response :not_found
  end

  test "results page shows Connect when configured but not connected, Export once connected" do
    prev = ENV.values_at("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GOOGLE_CLIENT_ID"]     = "id.apps.googleusercontent.com"
    ENV["GOOGLE_CLIENT_SECRET"] = "secret"

    get survey_results_path(@survey)
    assert_response :success
    assert_match "Connect Google Sheets", response.body

    @user.update!(google_refresh_token: "rt")
    get survey_results_path(@survey)
    assert_response :success
    assert_match "Export to Google Sheets", response.body
    assert_match survey_google_sheet_path(@survey, segment: "overall"), response.body
  ensure
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = prev
  end

  test "the CSV groups a responder's runs under one minted name, and never leaks a digest" do
    digest = @survey.respondent_code_digest("sam14")
    early  = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                                       respondent_code_digest: digest, created_at: 3.days.ago,
                                       answers: { "0" => { "type" => "multiple_choice", "value" => "Green" } })
    late   = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                                       respondent_code_digest: digest, created_at: 1.day.ago,
                                       answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })

    get survey_results_export_path(@survey, kind: "responses")
    assert_response :success

    parsed = CSV.parse(response.body.delete_prefix("﻿"), headers: true)
    assert_includes parsed.headers, "Responder"
    assert_includes parsed.headers, "Device group"

    rows  = parsed.map { |r| r }
    coded = rows.select { |r| r["Responder"].present? }
    assert_equal [ early.id.to_s, late.id.to_s ], coded.map { |r| r["Response ID"] },
                 "one responder's runs sit together, in play order"
    assert_equal 1, coded.map { |r| r["Responder"] }.uniq.size
    assert rows.last["Responder"].blank?, "the uncoded setup response trails the named group"

    assert_not_includes response.body, digest
    assert_not_includes response.body, "sam14"
  end

  test "results include partial (started) responders, excluding those who answered nothing" do
    # answered the question but never reached Submit — must now be counted
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "started", locale: "en",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Green" } })
    # opened but answered nothing — contributes to no question, so excluded
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "started", locale: "en", answers: {})

    get survey_results_path(@survey)
    assert_response :success
    assert_match "Green", response.body, "a partial responder's answer should show in results"

    get survey_results_export_path(@survey, kind: "responses")
    parsed = CSV.parse(response.body.delete_prefix("﻿"), headers: true)
    assert_equal 2, parsed.size, "the completed + the partial responder, but not the empty one"
    assert_equal %w[Blue Green], parsed.map { |r| r["Colour?"] }.compact.sort
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
