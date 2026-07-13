require "test_helper"

class PdfImportTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "pdf-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "pdf-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def pdf_upload(content_type = "application/pdf")
    Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/questions.pdf"), content_type
    )
  end

  # Stub PdfQuestionImporter.new so the controller gets an object whose #call
  # returns `result` without touching the Anthropic API. `new` is stubbed with a
  # lambda (stub_method invokes callables) that returns the fake instance.
  def stub_importer(result, &block)
    fake = Object.new
    fake.define_singleton_method(:call) { |**_| result }
    stub_method(PdfQuestionImporter, :new, ->(*_a, **_k) { fake }, &block)
  end

  test "the wizard exposes the Import from PDF entry point" do
    get new_survey_path
    assert_response :success
    assert_match "Import from PDF", response.body
    assert_match 'name="pdf"', response.body
    assert_match import_pdf_survey_path, response.body
  end

  test "importing a PDF preserves quiz mode chosen via the Create menu" do
    cards = [ { "type" => "select_one_grid", "text" => "Which best describes you?", "options" => %w[New Returning Lapsed Curious] } ]

    stub_importer({ "title" => "Imported", "cards" => cards }) do
      post import_pdf_survey_path, params: { pdf: pdf_upload, default_locale: "en", locales: [ "en" ], quiz: "1" }
    end

    survey = @org.surveys.order(:created_at).last
    assert survey.quiz?, "quiz mode chosen at the Create menu must survive a PDF import, not just AI generation"
  end

  test "importing a PDF creates a Verto from the matched questions and opens the editor" do
    cards = [
      { "type" => "select_one_grid", "text" => "Which best describes you?", "options" => %w[New Returning Lapsed Curious] },
      { "type" => "open_ended",      "text" => "What would make you stay?" }
    ]

    stub_importer({ "title" => "Imported", "description" => "Hi", "cards" => cards }) do
      assert_difference -> { @org.surveys.count }, 1 do
        post import_pdf_survey_path, params: { pdf: pdf_upload, default_locale: "en", locales: [ "en" ] }
      end
    end

    survey = @org.surveys.order(:created_at).last
    assert_redirected_to survey_path(survey)
    assert_equal "Imported", survey.title
    # 1 welcome card + 2 imported questions + the 3 set demographic questions
    assert_equal 6, Array(survey.cards).size
    assert_equal "welcome_card", survey.cards.first["type"]
    assert_equal "select_one_grid", survey.cards[1]["type"]
    demographics = survey.cards.select { |c| c["demographic"] }
    assert_equal [ "When were you born?", "Where do you live?", "Gender" ], demographics.map { |c| c["text"] }
    assert_equal demographics, survey.cards.last(3), "demographics must sit at the end"
  end

  test "non-compliant questions pause the import on a review screen" do
    cards = [
      { "type" => "open_ended", "text" => "What would make you stay?", "original_text" => "What would make you stay?", "compliant" => true },
      { "type" => "open_ended", "text" => "How could the programme improve?",
        "original_text" => "Thinking about everything you have experienced in the programme so far this year, in what ways do you feel it could be improved and why?",
        "compliant" => false, "issue" => "Over the 100-character cap." }
    ]

    stub_importer({ "title" => "Imported", "cards" => cards }) do
      assert_no_difference -> { @org.surveys.count } do
        post import_pdf_survey_path, params: { pdf: pdf_upload, default_locale: "en", locales: [ "en" ], verto_name: "Programme Review" }
      end
    end
    assert_response :success
    assert_match "don't meet Verto's guidelines", response.body
    assert_match "Thinking about everything you have experienced", response.body
    assert_match "How could the programme improve?", response.body
    assert_match "Optimise with Verto", response.body
    assert_match "Keep my wording", response.body
  end

  test "finalize keeps verbatim wording or takes the optimised version" do
    cards = [
      { "type" => "open_ended", "text" => "Short version?", "original_text" => "The very long original wording of this question?", "compliant" => false, "issue" => "Too long." }
    ]
    payload = {
      "result" => { "title" => "Imported", "cards" => cards },
      "verto_name" => "Named on import", "theme" => "", "audience_age" => "", "key_insight" => "",
      "brand_palette" => nil, "default_locale" => "en", "locales" => [ "en" ],
      "common_question_ids" => []
    }
    signed = SurveysController.import_verifier.generate(payload)

    post finalize_import_survey_path, params: { payload: signed, variant: "verbatim" }
    verbatim = @org.surveys.order(:id).last
    assert_redirected_to survey_path(verbatim)
    assert_equal "welcome_card", verbatim.cards.first["type"], "every imported Verto opens with a welcome card"
    imported = verbatim.cards.find { |c| c["type"] == "open_ended" }
    assert_equal "The very long original wording of this question?", imported["text"]
    assert_equal "Named on import", verbatim.title
    assert verbatim.cards.last["demographic"], "demographic tail appended on finalize"
    refute imported.key?("compliant"), "review-only fields are stripped from stored cards"

    post finalize_import_survey_path, params: { payload: signed, variant: "optimised" }
    optimised = @org.surveys.order(:id).last
    assert_equal "Short version?", optimised.cards.find { |c| c["type"] == "open_ended" }["text"]
  end

  test "a tampered finalize payload is rejected" do
    assert_no_difference -> { @org.surveys.count } do
      post finalize_import_survey_path, params: { payload: "garbage", variant: "verbatim" }
    end
    assert_redirected_to new_survey_path
  end

  test "a non-PDF upload re-renders the wizard with an error and creates nothing" do
    assert_no_difference -> { @org.surveys.count } do
      post import_pdf_survey_path, params: { pdf: pdf_upload("text/plain") }
    end
    assert_response :unprocessable_entity
    assert_match "Please choose a PDF file", response.body
  end

  test "a PDF with no extractable questions re-renders the wizard with an error" do
    stub_importer({ "title" => "Empty", "cards" => [] }) do
      assert_no_difference -> { @org.surveys.count } do
        post import_pdf_survey_path, params: { pdf: pdf_upload }
      end
    end
    assert_response :unprocessable_entity
    assert_match "couldn&#39;t find any questions", response.body
  end
end
