require "test_helper"

# The wizard's import doors run their slow read in the same background job
# creation uses, then hand back to the request for the one decision that needs
# the creator: straight to the editor, or pause at the review screen.
class VertoBuildImportTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "open_ended", "text" => "What would make you stay?" },
    { "type" => "yes_no", "text" => "Would you recommend us?", "options" => %w[Yes No] }
  ].freeze

  def setup
    @org  = Organisation.create!(name: "O", slug: "vbi-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "vbi-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def stub_manual(result, &block)
    fake = Object.new
    fake.define_singleton_method(:call) { |**_| result }
    stub_method(ManualQuestionImporter, :new, ->(*_a, **_k) { fake }, &block)
  end

  def paste(text = "What would make you stay?")
    post import_manual_survey_path, params: { manual_questions: text, default_locale: "en", locales: [ "en" ] }
  end

  test "pasting questions enqueues the read instead of doing it inline" do
    assert_enqueued_with(job: BuildVertoJob) { paste }

    build = @org.verto_builds.sole
    assert_equal "import_manual", build.kind
    assert build.import?
    assert_redirected_to verto_build_path(build)
    assert_nil build.result, "the read hasn't happened yet"
  end

  test "the job stores the imported questions without creating a Verto" do
    stub_manual({ "title" => "Imported", "cards" => CARDS }) do
      assert_no_difference -> { @org.surveys.count } do
        perform_enqueued_jobs { paste }
      end
    end

    build = @org.verto_builds.sole.reload
    assert build.succeeded?
    assert_nil build.survey, "an import stops short of a Verto — that call needs the creator"
    assert_equal 2, build.result["cards"].size
  end

  test "the wait screen forwards a finished import to its second leg" do
    stub_manual({ "title" => "Imported", "cards" => CARDS }) { perform_enqueued_jobs { paste } }
    build = @org.verto_builds.sole

    get verto_build_path(build)
    assert_redirected_to resume_import_path(build)
  end

  test "the poll endpoint points at the import's second leg, not a Verto" do
    stub_manual({ "title" => "Imported", "cards" => CARDS }) { perform_enqueued_jobs { paste } }
    build = @org.verto_builds.sole

    get verto_build_path(build, format: :json)
    assert_equal resume_import_path(build), JSON.parse(response.body)["redirect_to"]
  end

  test "a clean import creates the Verto on the second leg" do
    stub_manual({ "title" => "Imported", "cards" => CARDS }) { perform_enqueued_jobs { paste } }
    build = @org.verto_builds.sole

    assert_difference -> { @org.surveys.count }, 1 do
      get resume_import_path(build)
    end
    assert_redirected_to survey_path(@org.surveys.order(:id).last)
  end

  test "non-compliant questions still pause at the review screen" do
    flagged = [ CARDS[0].merge("compliant" => false, "issue" => "too long", "original_text" => "Original?") ]
    stub_manual({ "title" => "Imported", "cards" => flagged }) { perform_enqueued_jobs { paste } }

    assert_no_difference -> { @org.surveys.count } do
      get resume_import_path(@org.verto_builds.sole)
    end
    assert_response :success
    assert_match "Original?", response.body
  end

  test "an import that finds nothing fails the build with a reason" do
    stub_manual({ "title" => "Empty", "cards" => [] }) { perform_enqueued_jobs { paste } }

    build = @org.verto_builds.sole.reload
    assert build.failed?
    assert_match(/couldn't find any questions/i, build.error_message)
  end

  test "resuming an unfinished import sends the creator back rather than half-building" do
    paste # enqueued, never run
    get resume_import_path(@org.verto_builds.sole)
    assert_redirected_to new_survey_path
  end

  test "another organisation's import is not resumable" do
    stub_manual({ "title" => "Imported", "cards" => CARDS }) { perform_enqueued_jobs { paste } }
    build = @org.verto_builds.sole

    other_org  = Organisation.create!(name: "Other", slug: "vbi-o-#{SecureRandom.hex(3)}")
    other_user = User.create!(name: "X", email_address: "vbio-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    other_org.memberships.create!(user: other_user, role: "admin")
    delete session_path
    post session_path, params: { email_address: other_user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get resume_import_path(build)
    assert_response :not_found
  end

  test "a PDF's bytes are staged on the build, not carried through the queue" do
    pdf = Rack::Test::UploadedFile.new(
      StringIO.new("%PDF-1.4 fake"), "application/pdf", original_filename: "questions.pdf"
    )
    post import_pdf_survey_path, params: { pdf: pdf, default_locale: "en", locales: [ "en" ] }

    build = @org.verto_builds.sole
    assert_equal "import_pdf", build.kind
    assert build.source_file.attached?, "the upload should be an attachment, not base64 in the payload"
    assert_not_includes build.payload.to_json, "PDF-1.4"
  end
end
