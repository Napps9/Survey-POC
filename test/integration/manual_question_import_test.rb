require "test_helper"

class ManualQuestionImportTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "man-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "man-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # Stub ManualQuestionImporter.new so the controller gets an object whose
  # #call returns `result` without touching the Anthropic API — the same
  # pattern as pdf_import_test.
  def stub_importer(result, &block)
    fake = Object.new
    fake.define_singleton_method(:call) { |**_| result }
    stub_method(ManualQuestionImporter, :new, ->(*_a, **_k) { fake }, &block)
  end

  test "the wizard exposes the manual-questions entry point on the final card" do
    get new_survey_path
    assert_response :success
    assert_match 'name="manual_questions"', response.body
    assert_match import_manual_survey_path, response.body
    assert_match "Have your own questions?", response.body
  end

  test "pasted questions create a Verto from the matched questions and open the editor" do
    cards = [
      { "type" => "rating",     "text" => "How was the workshop?", "options" => %w[Poor Fair Good Great Excellent] },
      { "type" => "open_ended", "text" => "What should we change?" }
    ]

    stub_importer({ "title" => "Workshop Feedback", "description" => "Hi", "cards" => cards }) do
      assert_difference -> { @org.surveys.count }, 1 do
        post import_manual_survey_path, params: {
          manual_questions: "How was the workshop?\nWhat should we change?",
          default_locale: "en", locales: [ "en" ]
        }
      end
    end

    survey = @org.surveys.order(:created_at).last
    assert_redirected_to survey_path(survey)
    assert_equal "Workshop Feedback", survey.title
    # 1 welcome card + 2 pasted questions + the 3 set demographic questions
    assert_equal 6, Array(survey.cards).size
    assert_equal "welcome_card", survey.cards.first["type"]
    assert_equal "rating", survey.cards[1]["type"]
    assert survey.cards.last["demographic"], "demographic tail appended"
  end

  test "non-compliant questions pause the import on the review screen" do
    cards = [
      { "type" => "open_ended", "text" => "Shorter?", "original_text" => "A very long rambling question that goes on and on well past the character cap?", "compliant" => false, "issue" => "Over the 100-character cap." }
    ]

    stub_importer({ "title" => "Imported", "cards" => cards }) do
      assert_no_difference -> { @org.surveys.count } do
        post import_manual_survey_path, params: { manual_questions: "one question", default_locale: "en", locales: [ "en" ] }
      end
    end
    assert_response :success
    assert_match "don't meet Verto's guidelines", response.body
    assert_match "A very long rambling question", response.body
  end

  test "pasting questions preserves quiz mode chosen via the Create menu" do
    cards = [ { "type" => "rating", "text" => "How was the workshop?", "options" => %w[Poor Fair Good Great Excellent] } ]

    stub_importer({ "title" => "Workshop Feedback", "cards" => cards }) do
      post import_manual_survey_path, params: {
        manual_questions: "How was the workshop?", default_locale: "en", locales: [ "en" ], quiz: "1"
      }
    end

    survey = @org.surveys.order(:created_at).last
    assert survey.quiz?, "quiz mode chosen at the Create menu must survive a pasted-question import, not just AI generation"
  end

  test "blank text is rejected without calling the importer" do
    stub_method(ManualQuestionImporter, :new, ->(*) { raise "must not be instantiated" }) do
      assert_no_difference -> { @org.surveys.count } do
        post import_manual_survey_path, params: { manual_questions: "   " }
      end
    end
    assert_response :unprocessable_entity
    assert_match "Type or paste your questions", response.body
  end
end
