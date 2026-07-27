require "test_helper"

class PortfolioFlowTest < ActionDispatch::IntegrationTest
  def make_user(suffix, org)
    user = User.create!(name: "U#{suffix}", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    user
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # Stub SurveyGenerator so its output echoes the common_cards it was handed —
  # lets us observe exactly which questions were woven in.
  def with_echoing_generator
    fake = Object.new
    def fake.call(**kwargs)
      { "title" => "T", "description" => "d", "theme" => "T", "audience_age" => "a",
        "key_insight" => "k",
        "cards" => [ { "type" => "welcome_card", "title" => "hi" } ] + Array(kwargs[:common_cards]) }
    end
    SurveyGenerator.define_singleton_method(:new) { |*| fake }
    # Verto creation is a background job now (P0-3); these tests are about the
    # generation pipeline, so drain the queue inside the stub.
    perform_enqueued_jobs { yield }
  ensure
    SurveyGenerator.singleton_class.remove_method(:new)
  end

  def generate_with(question_ids: [])
    with_echoing_generator do
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0",
        common_question_ids: question_ids
      }
    end
    Survey.order(:id).last
  end

  def setup
    @funder_org = Organisation.create!(name: "Funder Org", slug: "funder-org-#{SecureRandom.hex(2)}", funder_enabled: true)
    @funder_admin = make_user("f", @funder_org)
    @funder = @funder_org.funders.create!(name: "Fund", seat_count: 5)

    @grantee = Organisation.create!(name: "Grantee Co", slug: "grantee-#{SecureRandom.hex(2)}")
    @grantee_admin = make_user("g", @grantee)
    @fm = FunderMembership.assign!(funder: @funder, organisation: @grantee)

    @set = @funder_org.common_question_sets.create!(name: "Core battery")
    @q1 = @set.common_questions.create!(text: "How confident do you feel?", card_type: "range")
    @q2 = @set.common_questions.create!(text: "Would you recommend us?", card_type: "yes_no")
  end

  test "creator attaches a set and adds an already-licensed org — its pre-existing Verto is backfilled" do
    existing_survey = @grantee.surveys.create!(
      title: "Existing Verto", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ]
    )

    sign_in @funder_admin
    post funder_portfolios_path(@funder), params: { portfolio: { name: "Climate" } }
    portfolio = Portfolio.last
    assert_redirected_to funder_portfolio_path(@funder, portfolio)

    post funder_portfolio_portfolio_common_question_sets_path(@funder, portfolio),
         params: { common_question_set_id: @set.id }
    assert_redirected_to funder_portfolio_path(@funder, portfolio)

    post funder_portfolio_portfolio_memberships_path(@funder, portfolio),
         params: { funder_membership_id: @fm.id }
    assert_redirected_to funder_portfolio_path(@funder, portfolio)

    attached = existing_survey.reload.cards.filter_map { |c| c["common_question_id"] }
    assert_equal [ @q1.id, @q2.id ].sort, attached.sort
  end

  test "a grantee creating a brand-new Verto gets mandatory cards even with no manual picks" do
    portfolio = @funder.portfolios.create!(name: "Climate")
    portfolio.portfolio_common_question_sets.create!(common_question_set: @set)
    portfolio.portfolio_memberships.create!(funder_membership: @fm)

    sign_in @grantee_admin
    survey = generate_with(question_ids: [])

    attached = survey.cards.filter_map { |c| c["common_question_id"] }
    assert_equal [ @q1.id, @q2.id ].sort, attached.sort
  end

  test "multi-funder/multi-portfolio isolation" do
    portfolio = @funder.portfolios.create!(name: "Climate")
    portfolio.portfolio_common_question_sets.create!(common_question_set: @set)
    portfolio.portfolio_memberships.create!(funder_membership: @fm)

    other_funder_org = Organisation.create!(name: "Other Funder", slug: "other-funder-#{SecureRandom.hex(2)}", funder_enabled: true)
    other_funder = other_funder_org.funders.create!(name: "Other Fund", seat_count: 5)
    other_fm = FunderMembership.assign!(funder: other_funder, organisation: @grantee)
    other_portfolio = other_funder.portfolios.create!(name: "Health")
    other_set = other_funder_org.common_question_sets.create!(name: "Health core")
    other_q = other_set.common_questions.create!(text: "Access to care?", card_type: "range")
    other_portfolio.portfolio_common_question_sets.create!(common_question_set: other_set)
    # @grantee is under Fund's Climate portfolio, but NOT Other Fund's Health
    # portfolio, even though other_fm exists — join! is never called for it.
    refute other_fm.portfolios.exists?(id: other_portfolio.id)

    sign_in @grantee_admin
    survey = generate_with(question_ids: [])
    attached = survey.cards.filter_map { |c| c["common_question_id"] }
    assert_equal [ @q1.id, @q2.id ].sort, attached.sort
    refute_includes attached, other_q.id, "a grantee not in a portfolio must not get that portfolio's questions"
  end

  test "a grantee deleting a mandatory card gets it re-appended on the next autosave" do
    portfolio = @funder.portfolios.create!(name: "Climate")
    portfolio.portfolio_common_question_sets.create!(common_question_set: @set)
    portfolio.portfolio_memberships.create!(funder_membership: @fm)

    survey = @grantee.surveys.create!(
      title: "V", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ] + [ @q1, @q2 ].map(&:to_card)
    )

    sign_in @grantee_admin
    stripped_cards = survey.cards.reject { |c| c["common_question_id"] == @q1.id }
    patch survey_path(survey), params: { cards: stripped_cards }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    assert_includes survey.reload.cards.filter_map { |c| c["common_question_id"] }, @q1.id,
      "the mandatory card must be re-appended, not stay deleted"
  end

  test "the funder dashboard groups a licensed org under its Portfolio, out of the flat list" do
    portfolio = @funder.portfolios.create!(name: "Climate")
    portfolio.portfolio_memberships.create!(funder_membership: @fm)

    unassigned_org = Organisation.create!(name: "Unassigned Org", slug: "unassigned-#{SecureRandom.hex(2)}")
    FunderMembership.assign!(funder: @funder, organisation: unassigned_org)

    sign_in @funder_admin
    get funder_path(@funder)
    assert_response :success
    assert_match "Climate", response.body
    assert_match "Grantee Co", response.body
    assert_match "Unassigned Org", response.body
    refute_match "%{funder}", response.body, "no raw locale placeholder should leak into rendered HTML"
  end

  test "a new portfolio can be created via the dashboard modal's POST target" do
    sign_in @funder_admin
    assert_difference -> { @funder.portfolios.count }, 1 do
      post funder_portfolios_path(@funder), params: { portfolio: { name: "Education" } }
    end
    assert_redirected_to funder_portfolio_path(@funder, Portfolio.last)
  end

  test "an invalid portfolio creation redirects back to the dashboard with an alert" do
    @funder.portfolios.create!(name: "Dup")
    sign_in @funder_admin

    post funder_portfolios_path(@funder), params: { portfolio: { name: "Dup" } }
    assert_redirected_to funder_path(@funder)
    follow_redirect!
    assert_response :success
    assert_match(/taken|already/i, response.body)
  end
end
