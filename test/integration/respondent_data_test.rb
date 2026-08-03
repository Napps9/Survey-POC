require "test_helper"

# GDPR data-subject rights (P0-7). Before this, respondent PII could only be
# removed by destroying the whole Verto — there was no responses controller and
# no routes at all.
#
# The creator is the data controller, so this is admin-only and org-scoped:
# unlike every other results view, which is careful to stay aggregate, these
# endpoints return one named individual's answers.
class RespondentDataTest < ActionDispatch::IntegrationTest
  def setup
    @org    = Organisation.create!(name: "O", slug: "rd-#{SecureRandom.hex(3)}")
    @admin  = User.create!(name: "A", email_address: "rd-a-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    @member = User.create!(name: "M", email_address: "rd-m-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    @org.memberships.create!(user: @admin, role: "admin")
    @org.memberships.create!(user: @member, role: "member")

    @survey = @org.surveys.create!(
      title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Do you feel safe?", "options" => %w[Yes No] },
               { "type" => "open_ended", "input" => "location", "text" => "Where do you live?",
                 "demographic" => true } ]
    )
    @token = SecureRandom.uuid
    @resp  = @survey.responses.create!(
      session_token: @token, status: "completed", answered: true,
      answers: { "0" => { "type" => "yes_no", "value" => "Yes" },
                 "1" => { "type" => "open_ended", "value" => "London" } },
      demographic_birth_year: 1990, demographic_gender: "Female",
      demographic_heritage: "Mixed or multiple heritage",
      demographic_neurodiversity: "|ADHD|Dyslexia|",
      region_country: "GB", region_label: "London", locale: "en", device_kind: "mobile",
      consent_agreed_at: Time.current, consent_text_snapshot: "You agreed to this.",
      started_at: 3.minutes.ago, completed_at: Time.current
    )
  end

  def login(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # ── Authorisation ───────────────────────────────────────────────────────

  test "a non-admin member cannot reach it" do
    login(@member)
    get survey_respondent_data_path(@survey)
    assert_redirected_to root_path

    get survey_respondent_data_export_path(@survey, session_token: @token)
    assert_redirected_to root_path

    delete survey_respondent_data_path(@survey, session_token: @token)
    assert_redirected_to root_path
    assert @resp.reload.persisted?
  end

  test "an admin of another organisation cannot reach this Verto's respondents" do
    other_org  = Organisation.create!(name: "X", slug: "rd-x-#{SecureRandom.hex(3)}")
    other_admin = User.create!(name: "X", email_address: "rd-x-#{SecureRandom.hex(3)}@test.com",
                               password: "verylongpassword")
    other_org.memberships.create!(user: other_admin, role: "admin")

    login(other_admin)
    get survey_respondent_data_path(@survey)
    assert_response :not_found
  end

  test "it is not reachable signed out" do
    get survey_respondent_data_path(@survey)
    assert_response :redirect
    assert_not_equal survey_respondent_data_path(@survey), response.location
  end

  # ── Lookup ──────────────────────────────────────────────────────────────

  test "an admin finds a respondent by session token" do
    login(@admin)
    get survey_respondent_data_path(@survey, session_token: @token)
    assert_response :success
    assert_match "##{@resp.id}", response.body
  end

  test "an unknown identifier reports no match rather than erroring" do
    login(@admin)
    get survey_respondent_data_path(@survey, session_token: "nope")
    assert_response :success
    assert_select "p", text: I18n.t("respondent_data.not_found")
  end

  test "opening the page with no query searches for nothing" do
    login(@admin)
    get survey_respondent_data_path(@survey)
    assert_response :success
    assert_select "p", text: I18n.t("respondent_data.not_found"), count: 0
  end

  test "a respondent code finds every wave that person answered" do
    # The whole point of respondent codes: one person, several responses.
    @survey.update!(respondent_code_enabled: true)
    digest = @survey.respondent_code_digest("Sam 14")
    a = @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                  status: "completed", answers: {})
    b = @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                  status: "completed", answers: {})

    login(@admin)
    get survey_respondent_data_path(@survey, respondent_code: "sam14")
    assert_response :success
    assert_match "##{a.id}", response.body
    assert_match "##{b.id}", response.body
  end

  # ── Export (Article 15 / 20) ────────────────────────────────────────────

  test "the export contains everything held, not just the answers" do
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)
    assert_response :success
    assert_equal "application/json", response.media_type

    row = JSON.parse(response.body)["responses"].first
    assert_equal 1990,     row["demographics"]["birth_year"]
    assert_equal "Female", row["demographics"]["gender"]
    assert_equal "London", row["demographics"]["region"]
    assert_equal "Mixed or multiple heritage", row["demographics"]["heritage"]
    assert_equal %w[ADHD Dyslexia], row["demographics"]["neurodiversity"],
                 "the packed column must unpack for a subject-access reader"
    assert_equal "mobile", row["device"]
    assert_equal "en",     row["language"]
    assert_equal "You agreed to this.", row["consent"]["agreed_to"]
    assert_not_nil row["consent"]["agreed_at"]
    assert_not_nil row["duration_seconds"]
  end

  test "answers are exported next to the question that was asked" do
    # Answers are stored keyed by card INDEX, which is meaningless to the person
    # receiving the file.
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)

    answers = JSON.parse(response.body)["responses"].first["answers"]
    assert_equal "Do you feel safe?", answers.first["question"]
    assert_equal "Yes",               answers.first["answer"]
    assert_equal "Where do you live?", answers.second["question"]
  end

  test "a respondent code is never exported in a reversible form" do
    @survey.update!(respondent_code_enabled: true)
    @resp.update!(respondent_code_digest: @survey.respondent_code_digest("secret-code"))

    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: @token)

    assert_not_includes response.body, "secret-code"
    assert_not_includes response.body, @resp.reload.respondent_code_digest
    assert_equal true, JSON.parse(response.body)["responses"].first["respondent_code"]["linked"]
  end

  test "exporting an unknown identifier says so rather than sending an empty file" do
    login(@admin)
    get survey_respondent_data_export_path(@survey, session_token: "nope")
    assert_redirected_to survey_respondent_data_path(@survey)
    assert_equal I18n.t("respondent_data.not_found"), flash[:alert]
  end

  # ── Erasure (Article 17) ────────────────────────────────────────────────

  test "erasing removes the row outright rather than blanking it" do
    login(@admin)
    assert_difference -> { @survey.responses.count }, -1 do
      delete survey_respondent_data_path(@survey, session_token: @token)
    end
    assert_redirected_to survey_respondent_data_path(@survey)
    assert_nil Response.find_by(session_token: @token)
  end

  test "erasing by respondent code removes every wave" do
    @survey.update!(respondent_code_enabled: true)
    digest = @survey.respondent_code_digest("Sam 14")
    2.times do
      @survey.responses.create!(session_token: SecureRandom.uuid, respondent_code_digest: digest,
                                status: "completed", answers: {})
    end

    login(@admin)
    assert_difference -> { @survey.responses.count }, -2 do
      delete survey_respondent_data_path(@survey, respondent_code: "sam14")
    end
    # The unrelated respondent is untouched.
    assert Response.exists?(session_token: @token)
  end

  test "erasing nothing does not claim to have erased something" do
    login(@admin)
    assert_no_difference -> { @survey.responses.count } do
      delete survey_respondent_data_path(@survey, session_token: "nope")
    end
    assert_equal I18n.t("respondent_data.not_found"), flash[:alert]
  end

  test "a lookup with no identifier at all never matches every respondent" do
    # The dangerous failure mode: a blank query falling through to
    # survey.responses and erasing the lot.
    login(@admin)
    assert_no_difference -> { @survey.responses.count } do
      delete survey_respondent_data_path(@survey)
    end
  end

  test "an identifier from one Verto does not reach another's respondents" do
    other = @org.surveys.create!(title: "T2", theme: "Th", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    login(@admin)

    get survey_respondent_data_path(other, session_token: @token)
    assert_response :success
    assert_select "p", text: I18n.t("respondent_data.not_found")

    delete survey_respondent_data_path(other, session_token: @token)
    assert Response.exists?(session_token: @token)
  end

  test "the same code hashes differently in a different Verto" do
    # respondent_code_key is derived per survey id, so a code cannot be used to
    # find the same person across Vertos — including from this tool.
    other = @org.surveys.create!(title: "T2", theme: "Th", audience_age: "adults", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    assert_not_equal @survey.respondent_code_digest("sam14"), other.respondent_code_digest("sam14")
  end

  # ── The entry point ─────────────────────────────────────────────────────

  test "admins see the link on the results page and members don't" do
    # The results page renders a play link, so it needs a published Verto.
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    login(@admin)
    get survey_results_path(@survey)
    assert_select "a[href=?]", survey_respondent_data_path(@survey), 1

    delete session_path
    login(@member)
    get survey_results_path(@survey)
    assert_select "a[href=?]", survey_respondent_data_path(@survey), 0
  end
end
