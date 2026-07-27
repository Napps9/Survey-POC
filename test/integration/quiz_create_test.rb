require "test_helper"

# The "Make this a quiz" toggle flows from the wizard into the survey, the
# generator is told to grade, and — crucially — the live player never receives
# the correct answers (only owner preview does).
class QuizCreateTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "quiz-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "quiz-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def with_recording_generator(received)
    fake = Object.new
    fake.define_singleton_method(:call) do |**kw|
      received.merge!(kw)
      { "title" => "Quiz", "description" => "d", "theme" => "T", "audience_age" => "a", "key_insight" => "k",
        "cards" => [ { "type" => "welcome_card", "title" => "hi" },
                     { "type" => "multiple_choice", "text" => "Capital of France?",
                       "options" => [ "Paris", "London" ], "correct" => "Paris", "explanation" => "Since 987." } ] }
    end
    SurveyGenerator.define_singleton_method(:new) { |*| fake }
    # Verto creation is a background job now (P0-3); these tests are about the
    # generation pipeline, so drain the queue inside the stub.
    perform_enqueued_jobs { yield }
  ensure
    SurveyGenerator.singleton_class.remove_method(:new)
  end

  test "the wizard offers the quiz toggle" do
    get new_survey_path
    assert_response :success
    assert_match 'name="quiz"', response.body
  end

  test "quiz=1 marks the Verto a quiz and tells the generator to grade" do
    received = {}
    with_recording_generator(received) do
      post generate_survey_path, params: {
        verto_name: "Geo Quiz", theme: "T", audience_age: "a", key_insight: "k",
        show_results_comparison: "0", quiz: "1"
      }
    end
    survey = @org.surveys.order(:id).last
    assert survey.quiz?, "the survey is a quiz"
    assert_equal true, received[:quiz], "the generator was asked to grade"
    graded = survey.cards.find { |c| c["type"] == "multiple_choice" }
    assert_equal "Paris", graded["correct"], "the correct answer is stored on the card"
    assert_equal 1, survey.quiz_question_count
  end

  test "the live player is sent the graded flag but NEVER the correct answer" do
    survey = @org.surveys.create!(title: "Q", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ], quiz: true,
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[Paris London],
                 "correct" => "Paris", "explanation" => "secret-rationale-xyz" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_match 'data-card-graded="true"', response.body
    refute_match "data-card-correct", response.body, "the live page must not leak which option is correct"
    refute_match "secret-rationale-xyz", response.body, "the explanation must not leak before answering"
  end

  test "owner preview DOES embed the correct answer so the reveal works offline" do
    survey = @org.surveys.create!(title: "Q", theme: "T", audience_age: "a", key_insight: "k",
      default_locale: "en", locales: [ "en" ], quiz: true,
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[Paris London], "correct" => "Paris" } ])

    get preview_survey_path(survey)
    assert_response :success
    assert_match "data-card-correct", response.body
  end
end
