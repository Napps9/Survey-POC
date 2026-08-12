require "test_helper"

# The creator's view of the leaderboard on /surveys/:id/results: whole-Verto
# standings under the retake policy, anonymous names only, bounded rows. The
# standings maths is locked by token_leaderboard_test; this locks what the
# results page shows and hides.
class LeaderboardResultsPageTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[Pizza Salad],
      "tokens" => { "Pizza" => { "gold" => 5 } } }
  ].freeze
  TYPES = [ { "id" => "gold", "name" => "Gold", "icon" => "🪙" } ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "lbr-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "lbr-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def board_survey(**attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                         tokenisation_enabled: true, token_types: TYPES,
                         leaderboard_enabled: true,
                         publish_token: SecureRandom.urlsafe_base64(18),
                         published_at: Time.current, **attrs)
  end

  def finish!(survey, key:, total:, at: 1.hour.ago)
    survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                             player_key_digest: survey.player_key_digest(key),
                             token_totals: { "gold" => total }, completed_at: at,
                             answers: { "0" => { "type" => "multiple_choice", "value" => "Pizza" } })
  end

  test "the results page lists the standings with anonymous names, best first" do
    s = board_survey
    finish! s, key: "second", total: 3, at: 2.hours.ago
    finish! s, key: "first",  total: 9

    get survey_results_path(s)
    assert_response :success
    assert_match "🏆 Leaderboard", response.body
    assert_match "2 players", response.body

    names = s.player_aliases.order(:id).pluck(:key_digest, :anon_name).to_h
    first_name  = names[s.player_key_digest("first")]
    second_name = names[s.player_key_digest("second")]
    assert first_name.present?, "rendering the page must backfill names for bare identities"
    assert response.body.index(first_name) < response.body.index(second_name),
           "9 tokens must list above 3"
  end

  test "standings on the page follow the retake policy" do
    s = board_survey(leaderboard_retake_policy: "accumulate")
    finish! s, key: "replayer", total: 4, at: 3.hours.ago
    finish! s, key: "replayer", total: 5

    get survey_results_path(s)
    assert_match(/\b1 player\b(?!s)/, response.body, "two runs, one identity, one row")
    assert_match "Retakes add points", response.body
    assert_match ">9<", response.body, "accumulate sums the runs"
  end

  test "the section is bounded and says so" do
    s = board_survey
    25.times { |i| finish! s, key: "p#{i}", total: 30 - i }

    get survey_results_path(s)
    assert_match "25 players", response.body
    assert_match "Showing the top 20 of 25.", response.body
  end

  test "no board section without the feature active" do
    off = board_survey(leaderboard_enabled: false)
    finish! off, key: "someone", total: 5
    get survey_results_path(off)
    assert_response :success
    assert_no_match "🏆 Leaderboard", response.body

    inert = board_survey(tokenisation_enabled: false)
    get survey_results_path(inert)
    assert_no_match "🏆 Leaderboard", response.body, "leaderboard_enabled without tokens ranks nothing"
  end

  test "the empty board renders an explanation, not a blank card" do
    s = board_survey
    get survey_results_path(s)
    assert_match "🏆 Leaderboard", response.body
    assert_match "No players on the board yet", response.body
  end
end
