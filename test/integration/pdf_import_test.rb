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
    assert_equal 2, Array(survey.cards).size
    assert_equal "select_one_grid", survey.cards.first["type"]
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
