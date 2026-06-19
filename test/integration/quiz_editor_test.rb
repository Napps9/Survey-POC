require "test_helper"

# The editor of a quiz Verto exposes correct-answer controls on each question
# card, and reflects already-marked answers back into the DOM.
class QuizEditorTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "qe-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "qe-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def quiz_survey
    @org.surveys.create!(title: "Q", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ], quiz: true,
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "text" => "Capital?", "options" => %w[Paris London], "correct" => "Paris" },
        { "type" => "open_ended", "text" => "2+2?", "correct" => [ "4" ] }
      ])
  end

  test "the editor renders correct-answer controls and reflects what's marked" do
    s = quiz_survey
    get survey_path(s)
    assert_response :success
    assert_match 'data-survey-editor-quiz-value="true"', response.body
    assert_match "click->survey-editor#toggleCorrect", response.body, "options carry a mark-correct toggle"
    assert_select ".quiz-correct-block", { minimum: 1 }, "a correct-answer block is rendered"
    # The marked option is reflected back as data-correct="true".
    assert_select '.pick-item[data-canonical="Paris"][data-correct="true"]'
    assert_select '.pick-item[data-canonical="London"][data-correct="false"]'
    # The open-ended accepted-answers control is prefilled.
    assert_select "textarea[data-quiz-accepted]", text: /4/
  end

  test "the publish panel shows the quiz toggle as on, with the graded count" do
    s = quiz_survey
    get survey_path(s)
    assert_response :success
    assert_match "Quiz mode", response.body
    assert_match "2 of 2 questions graded", response.body
  end

  test "a non-quiz editor renders no correct-answer controls" do
    s = @org.surveys.create!(title: "N", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] } ])
    get survey_path(s)
    assert_response :success
    assert_match 'data-survey-editor-quiz-value="false"', response.body
    assert_select ".quiz-correct-block", false
    refute_match "survey-editor#toggleCorrect", response.body
  end
end
