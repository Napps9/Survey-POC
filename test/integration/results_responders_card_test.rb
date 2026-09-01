require "test_helper"

# The Responders card: pseudonymous per-responder counts on the results page.
# Counts only, minted names only — the grouped answers live in the export's
# Responder column, and the per-person drill-down stays behind the admin-gated
# respondent-data page. Codes and digests must never reach the page body.
class ResultsRespondersCardTest < ActionDispatch::IntegrationTest
  def setup
    @admin  = User.create!(name: "A", email_address: "ra-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @member = User.create!(name: "M", email_address: "rm-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org = Organisation.create!(name: "O", slug: "rrc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @admin, role: "admin")
    @org.memberships.create!(user: @member, role: "member")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: 10.days.ago)
  end

  # answered is recomputed from `answers` content by Response's before_save,
  # so the card's answered: true scope needs a real answer behind each row.
  ANSWERS = { "0" => { "value" => "Blue" } }.freeze

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def coded_response(code, at: Time.current, wave: nil)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: ANSWERS,
                              respondent_code_digest: @survey.respondent_code_digest(code),
                              survey_wave_id: wave&.id,
                              created_at: at, updated_at: at)
  end

  test "each responder's plays appear under a minted name, never a code or digest" do
    # Not "sam14": that string legitimately appears on every page as the
    # respondent-code placeholder copy in the window.I18N blob.
    coded_response("zx91q", at: 2.days.ago)
    coded_response("zx91q", at: 1.day.ago)
    coded_response("blue7", at: 1.day.ago)

    sign_in(@admin)
    get survey_results_path(@survey)
    assert_response :success

    assert_match "🔑 Responders", response.body
    assert_match "2 responders", response.body
    assert_match "2 plays", response.body
    name = RespondentAlias.find_by!(survey: @survey,
                                    code_digest: @survey.respondent_code_digest("zx91q")).anon_name
    assert_match name, response.body
    assert_match "Names are system-made and anonymous", response.body

    assert_not_includes response.body, @survey.respondent_code_digest("zx91q")
    assert_not_includes response.body, "zx91q"
  end

  test "no coded responses, no card" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS)

    sign_in(@admin)
    get survey_results_path(@survey)
    assert_response :success
    assert_no_match(/🔑 Responders/, response.body)
  end

  test "a non-admin member sees the card — counts only is aggregate-grade" do
    coded_response("sam14")

    sign_in(@member)
    get survey_results_path(@survey)
    assert_response :success
    assert_match "🔑 Responders", response.body
  end

  test "pre-wave runs count under wave 1 in the waves-covered column" do
    coded_response("sam14", at: 5.days.ago) # implicit wave 1
    @survey.start_next_wave!
    coded_response("sam14", at: 1.hour.ago, wave: @survey.current_wave)

    sign_in(@admin)
    get survey_results_path(@survey)
    assert_match "2 of 2 waves", response.body
  end

  test "the list caps at the leaderboard row limit with an overflow line" do
    21.times { |i| coded_response("code-#{i}", at: i.hours.ago) }

    sign_in(@admin)
    get survey_results_path(@survey)
    assert_match "Showing the top 20 of 21.", response.body
    assert_match "21 responders", response.body
  end

  test "the public share page never gains the card or the names" do
    coded_response("sam14")
    sign_in(@admin)
    get survey_results_path(@survey) # mints the alias via the creator view
    post results_share_survey_path(@survey)
    token = @survey.reload.results_share_token

    get shared_results_path(token)
    assert_response :success
    assert_no_match(/Responders/, response.body)
    name = RespondentAlias.find_by!(survey: @survey,
                                    code_digest: @survey.respondent_code_digest("sam14")).anon_name
    assert_not_includes response.body, name
  end
end
