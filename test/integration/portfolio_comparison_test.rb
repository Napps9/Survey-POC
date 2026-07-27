require "test_helper"

# The funder-facing comparison view: grantee organisations side by side on the
# Common Questions the portfolio mandated across them.
class PortfolioComparisonTest < ActionDispatch::IntegrationTest
  MIN = Response::MIN_REGION_SAMPLE_SIZE

  def setup
    @funder_org = Organisation.create!(name: "Funder Org", slug: "pc-f-#{SecureRandom.hex(3)}", funder_enabled: true)
    @user = User.create!(name: "F", email_address: "pc-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @funder_org.memberships.create!(user: @user, role: "admin")
    @funder    = @funder_org.funders.create!(name: "Programme", seat_count: 10)
    @portfolio = @funder.portfolios.create!(name: "Cohort A")

    @set = @funder_org.common_question_sets.create!(name: "Core outcomes")
    @question = @set.common_questions.create!(
      text: "Do you feel supported?", card_type: "yes_no", options: %w[Yes No]
    )
    @portfolio.portfolio_common_question_sets.create!(common_question_set: @set)

    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # A grantee org in the portfolio, running a Verto that uses the mandated set.
  def grantee(name, yes:, no:)
    org = Organisation.create!(name: name, slug: "pc-g-#{SecureRandom.hex(3)}")
    membership = @funder.funder_memberships.create!(organisation: org, status: "active")
    @portfolio.portfolio_memberships.create!(funder_membership: membership)

    survey = org.surveys.create!(
      title: name, theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ @question.to_card.merge("cid" => "c_q") ]
    )
    yes.times { survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: { "0" => { "value" => "Yes" } }) }
    no.times  { survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: { "0" => { "value" => "No" } }) }
    org
  end

  test "the comparison renders each grantee as its own column" do
    grantee("Riverside Trust", yes: MIN, no: 0)
    grantee("Hillside Project", yes: 0, no: MIN)

    get results_funder_portfolio_path(@funder, @portfolio)
    assert_response :success
    assert_match "Riverside Trust", response.body
    assert_match "Hillside Project", response.body
    assert_match "Do you feel supported?", response.body
    assert_select "table.pf-table", minimum: 1
  end

  test "the two grantees' answers differ in the table, side by side" do
    grantee("All yes", yes: MIN, no: 0)
    grantee("All no",  yes: 0, no: MIN)

    get results_funder_portfolio_path(@funder, @portfolio)
    # One column is 100% Yes, the other 0% — the comparison is the point.
    assert_match "100%", response.body
    assert_match "0%", response.body
  end

  test "a grantee too small to break down is counted but never itemised" do
    # A funder reading a three-response grantee's answers is exactly what the
    # small-cell threshold exists to prevent everywhere else in this app.
    grantee("Big enough", yes: MIN, no: 0)
    grantee("Tiny", yes: 1, no: 1)

    get results_funder_portfolio_path(@funder, @portfolio)
    assert_response :success
    assert_match "Tiny", response.body
    assert_match "too small to break down", response.body
    assert_select "span.pf-suppressed", minimum: 1
  end

  test "the JSON payload still serves the pooled aggregate" do
    grantee("Riverside Trust", yes: MIN, no: 0)

    get results_funder_portfolio_path(@funder, @portfolio, format: :json)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @portfolio.name, body.dig("portfolio", "name")
    assert body["sets"].any?
  end

  test "an empty portfolio explains itself instead of rendering a blank table" do
    get results_funder_portfolio_path(@funder, @portfolio)
    assert_response :success
    assert_match(/No grantee has run a Verto using this set/i, response.body)
  end

  test "a portfolio with no question sets says so" do
    @portfolio.portfolio_common_question_sets.destroy_all

    get results_funder_portfolio_path(@funder, @portfolio)
    assert_response :success
    assert_match(/No Common Question sets are attached/i, response.body)
  end

  test "a suspended grantee drops out of the comparison" do
    grantee("Active Trust", yes: MIN, no: 0)
    suspended = grantee("Suspended Trust", yes: MIN, no: 0)
    @funder.funder_memberships.find_by!(organisation: suspended).update!(status: "suspended")

    get results_funder_portfolio_path(@funder, @portfolio)
    assert_match "Active Trust", response.body
    assert_no_match(/Suspended Trust/, response.body)
  end

  test "another account's portfolio is not reachable" do
    other_org = Organisation.create!(name: "Other", slug: "pc-o-#{SecureRandom.hex(3)}", funder_enabled: true)
    other_user = User.create!(name: "O", email_address: "pco-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    other_org.memberships.create!(user: other_user, role: "admin")
    delete session_path
    post session_path, params: { email_address: other_user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get results_funder_portfolio_path(@funder, @portfolio)
    assert_not_equal 200, response.status, "a funder's portfolio must not be readable by another account"
  end
end
