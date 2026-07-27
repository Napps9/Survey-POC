require "test_helper"

class PortfolioResultsTest < ActionDispatch::IntegrationTest
  def make_user(suffix, org)
    user = User.create!(name: "U#{suffix}", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    user
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def setup
    @funder_org = Organisation.create!(name: "Funder Org", slug: "funder-org-#{SecureRandom.hex(2)}", funder_enabled: true)
    @funder_admin = make_user("f", @funder_org)
    @funder = @funder_org.funders.create!(name: "Fund", seat_count: 5)

    @grantee = Organisation.create!(name: "Grantee Co", slug: "grantee-#{SecureRandom.hex(2)}")
    @grantee_admin = make_user("g", @grantee)
    @fm = FunderMembership.assign!(funder: @funder, organisation: @grantee)

    @portfolio = @funder.portfolios.create!(name: "Climate")
    @set = @funder_org.common_question_sets.create!(name: "Core battery")
    @q1 = @set.common_questions.create!(text: "How confident do you feel?", card_type: "range")
    @portfolio.portfolio_common_question_sets.create!(common_question_set: @set)
    @portfolio.portfolio_memberships.create!(funder_membership: @fm)

    @private_question_text = "What's your secret annual budget figure?"
    @private_answer_text = "GBP 4.2 million, do not tell the funder"

    @survey = @grantee.surveys.create!(
      title: "Grantee Verto", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        @q1.to_card,
        { "type" => "open_ended", "text" => @private_question_text }
      ]
    )
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: {
      "1" => { "type" => "range", "value" => 4 },
      "2" => { "type" => "open_ended", "value" => @private_answer_text }
    })
  end

  test "funder results shows the mandatory aggregate but never a grantee's other question text or answer" do
    sign_in @funder_admin
    get results_funder_portfolio_path(@funder, @portfolio, format: :json)
    assert_response :success

    body = response.parsed_body
    set_payload = body["sets"].find { |s| s["common_question_set_id"] == @set.id }
    assert set_payload, "expected the attached set to appear in the results payload"
    question_payload = set_payload["questions"].find { |q| q["common_question_id"] == @q1.id }
    assert question_payload, "expected the mandatory question's aggregate to appear"
    assert_equal 1, question_payload["total"]

    refute_match @private_question_text, response.body
    refute_match @private_answer_text, response.body
  end

  test "the grantee's own admin is redirected — funder-owner-only" do
    sign_in @grantee_admin
    get results_funder_portfolio_path(@funder, @portfolio, format: :json)
    assert_redirected_to funder_path(@funder)
  end

  test "suspending the grantee's license removes it from a subsequent results call" do
    sign_in @funder_admin
    get results_funder_portfolio_path(@funder, @portfolio, format: :json)
    set_payload = response.parsed_body["sets"].find { |s| s["common_question_set_id"] == @set.id }
    assert_equal 1, set_payload["total_responses"]

    @fm.suspend!

    get results_funder_portfolio_path(@funder, @portfolio, format: :json)
    set_payload_after = response.parsed_body["sets"].find { |s| s["common_question_set_id"] == @set.id }
    assert_equal 0, set_payload_after["total_responses"]
  end
end
