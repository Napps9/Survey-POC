require "test_helper"

class WizardCreateTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "wiz-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "wiz-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def with_fake_generator
    fake = Object.new
    def fake.call(**)
      { "title" => "AI title", "description" => "d", "theme" => "T", "audience_age" => "a",
        "key_insight" => "k", "cards" => [ { "type" => "welcome_card", "title" => "hi" },
                                           { "type" => "yes_no", "text" => "Like it?", "options" => [ "Yes", "No" ] } ] }
    end
    SurveyGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SurveyGenerator.singleton_class.remove_method(:new)
  end

  test "the wizard asks for a Verto name and it becomes the title" do
    get new_survey_path
    assert_response :success
    assert_match 'name="verto_name"', response.body

    with_fake_generator do
      post generate_survey_path, params: {
        verto_name: "Youth Wellbeing Check-in", theme: "T", audience_age: "a",
        key_insight: "k", show_results_comparison: "0"
      }
    end
    survey = @org.surveys.order(:id).last
    assert_equal "Youth Wellbeing Check-in", survey.title
  end

  test "without a name the AI title is the fallback" do
    with_fake_generator do
      post generate_survey_path, params: {
        theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0"
      }
    end
    assert_equal "AI title", @org.surveys.order(:id).last.title
  end

  test "every generated Verto ends with the 3 set demographic questions" do
    with_fake_generator do
      post generate_survey_path, params: {
        verto_name: "N", theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0"
      }
    end
    survey = @org.surveys.order(:id).last
    tail = survey.cards.last(3)
    assert tail.all? { |c| c["demographic"] }, "last three cards must be the demographic tail"
    assert_equal [ "When were you born?", "Where do you live?", "Gender" ], tail.map { |c| c["text"] }
    assert_equal [ "Male", "Female", "Prefer not to say" ], tail.last["options"]
  end

  test "the wizard tells the creator about the demographic tail" do
    get new_survey_path
    assert_response :success
    assert_match "3 set demographic questions", response.body
  end

  test "common questions alone create a Verto without AI generation" do
    set = @org.common_question_sets.create!(name: "Core")
    q   = set.common_questions.create!(text: "How confident are you?", card_type: "range")

    boom = Object.new
    def boom.call(**) = raise("SurveyGenerator must not be called")
    SurveyGenerator.define_singleton_method(:new) { |*| boom }
    begin
      post generate_survey_path, params: {
        verto_name: "Commons only", theme: "T", audience_age: "a",
        show_results_comparison: "0", common_question_ids: [ q.id ]
      }
    ensure
      SurveyGenerator.singleton_class.remove_method(:new)
    end

    survey = @org.surveys.order(:id).last
    assert_redirected_to survey_path(survey)
    assert_equal "Commons only", survey.title
    types = survey.cards.map { |c| c["type"] }
    assert_equal "welcome_card", types.first
    assert(survey.cards.any? { |c| c["common_question_id"] == q.id })
    assert survey.cards.last["demographic"], "demographic tail still appended"
  end

  test "neither a learning goal nor common questions is rejected" do
    assert_no_difference -> { @org.surveys.count } do
      post generate_survey_path, params: {
        verto_name: "N", theme: "T", audience_age: "a", show_results_comparison: "0"
      }
    end
    assert_response :unprocessable_entity
    assert_match "Common Questions", response.body
  end

  test "the birth demographic renders as a date picker in the player" do
    with_fake_generator do
      post generate_survey_path, params: {
        verto_name: "N", theme: "T", audience_age: "a", key_insight: "k", show_results_comparison: "0"
      }
    end
    survey = @org.surveys.order(:id).last
    survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_match 'type="date"', response.body
  end
end
