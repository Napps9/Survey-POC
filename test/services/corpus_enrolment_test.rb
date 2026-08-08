require "test_helper"

# Turning both consent keys from an import.
#
# The gate is the product's credibility, so the assertion that matters most is
# the one about what this REFUSES to do: a Verto the automated checks would have
# blocked is offered and left for a person, never waved through. That is what
# makes a "pre-approved" import safe to offer at all.
class CorpusEnrolmentTest < ActiveSupport::TestCase
  def setup
    @org  = Organisation.create!(name: "Importer", slug: "ce-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Imp", email_address: "ce-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def survey_with(responses:, cards: nil)
    cards ||= [ { "type" => "multiple_choice", "cid" => "c_a", "text" => "Why?",
                  "options" => [ "Money", "Time" ] } ]
    survey = @org.surveys.create!(title: "Imported", theme: "Education", audience_age: "all",
                                  key_insight: "x", default_locale: "en", locales: [ "en" ],
                                  cards: cards)
    responses.times do |i|
      survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                               answers: { "0" => { "value" => i.even? ? "Money" : "Time" } })
    end
    survey
  end

  def enrol(survey)
    CorpusEnrolment.new(survey, user: @user, reviewer: "import@vertonow.com").call
  end

  test "a healthy Verto is offered, approved and indexed in one step" do
    result = enrol(survey_with(responses: 40))

    assert result.approved?
    assert result.entry.citable?
    assert_equal "import@vertonow.com", result.entry.reviewed_by_email
    assert_operator result.questions, :>, 0
    assert_equal 1, CorpusTools.new.coverage[:vertos]
  end

  # The guarantee that makes this safe.
  test "a Verto below the sample floor is offered but NOT approved" do
    result = enrol(survey_with(responses: CorpusEntry::MIN_SAMPLE_SIZE - 1))

    assert result.blocked?
    assert_not result.entry.citable?
    assert result.entry.opted_in?, "it is offered — a person can still decide"
    assert_equal "pending", result.entry.review_status
    assert(result.blocked_by.any? { |r| r.include?("Fewer than") })
    assert_equal 0, CorpusTools.new.coverage[:vertos]
  end

  test "a Verto with no citable questions is offered but NOT approved" do
    # Contact forms are never indexed, so a deck of only those has nothing to cite.
    survey = survey_with(responses: 40,
                         cards: [ { "type" => "contact_form", "cid" => "c_cf", "text" => "Stay in touch" } ])

    result = enrol(survey)

    assert result.blocked?
    assert(result.blocked_by.any? { |r| r.include?("can be cited") })
  end

  test "a Verto with no responses at all is offered but NOT approved" do
    # The Walls Happiness Project shape: a real deck nobody has answered yet.
    result = enrol(survey_with(responses: 0))

    assert result.blocked?
    assert_not result.entry.citable?
    assert_equal 0, result.questions
  end

  test "warnings are reported but do not stop an import" do
    survey = survey_with(responses: 40, cards: [
      { "type" => "multiple_choice", "cid" => "c_a", "text" => "Why?", "options" => %w[Money Time] },
      { "type" => "open_ended", "cid" => "c_o", "text" => "What is the name of your school?" }
    ])

    result = enrol(survey)

    assert result.approved?, "a warning is something to read, not a reason to refuse"
    assert result.warnings.any?
  end

  test "the checks that were run are stored on the entry for the queue to render" do
    result = enrol(survey_with(responses: 40))

    stored = result.entry.check_results["checks"]
    assert stored.present?
    assert(stored.all? { |c| c.key?("status") && c.key?("label") })
  end

  test "enrolling twice does not re-date the original consent" do
    survey = survey_with(responses: 40)
    first  = enrol(survey)
    original = first.entry.opted_in_at

    second = enrol(survey)

    assert second.approved?
    assert_in_delta original.to_f, second.entry.opted_in_at.to_f, 0.001
    assert_equal 1, CorpusEntry.where(survey_id: survey.id).count
  end

  test "indexing can be deferred" do
    result = CorpusEnrolment.new(survey_with(responses: 40), user: @user,
                                 reviewer: "import@vertonow.com").call(index: false)

    assert result.approved?
    assert_equal 0, result.entry.corpus_questions.count
    assert_nil result.entry.indexed_at
  end
end
