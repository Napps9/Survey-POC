require "test_helper"

# The contact card (`contact_form`) is the first — and only — card type that
# collects identifying respondent data, so its contract is pinned end to end:
# object-shaped answers stored and counted, server-side field allowlist +
# clamping + email validation on the public JSON endpoint, results/CSV/GDPR
# surfacing, and the AI generator deliberately never producing one.
class ContactCardTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Leads", slug: "leads-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "lead-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def survey_with_contact(published: true)
    s = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "contact_form", "cid" => "cf1", "text" => "Stay in touch?" } ]
    )
    s.update!(publish_token: SecureRandom.hex(8)) if published
    s
  end

  def answer!(survey, value)
    post progress_survey_path(survey.publish_token),
         params: { answers: { "0" => { "type" => "contact_form", "value" => value } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    survey.responses.order(:id).last.tap { |r| r.update!(status: "completed") }
  end

  test "a contact answer is stored as an object and counts as answered" do
    resp = answer!(survey_with_contact,
                   { "name" => "Ada Lovelace", "company" => "Analytical Engines",
                     "industry" => "Computing", "email" => "ada@example.com" })

    assert_equal "Ada Lovelace", resp.answers["0"]["value"]["name"]
    assert_equal "ada@example.com", resp.answers["0"]["value"]["email"]
    assert Response.answered_entry?(resp.answers["0"])
  end

  test "unknown fields are stripped, long fields clamped, on the public endpoint" do
    resp = answer!(survey_with_contact,
                   { "name" => "A" * 500, "role" => "CEO", "admin" => true, "email" => "a@b.co" })

    value = resp.answers["0"]["value"]
    assert_equal Survey::CONTACT_FIELD_LIMIT, value["name"].length
    refute value.key?("role")
    refute value.key?("admin")
  end

  test "a malformed email is dropped server-side; other fields survive" do
    resp = answer!(survey_with_contact, { "name" => "Ada", "email" => "not-an-email" })

    value = resp.answers["0"]["value"]
    assert_equal "Ada", value["name"]
    refute value.key?("email"), "a public JSON endpoint can't rely on the browser to validate this"
  end

  test "an all-blank or scalar value is not an answer" do
    resp = answer!(survey_with_contact, { "name" => "  ", "email" => "" })
    refute Response.answered_entry?(resp.answers["0"])

    resp = answer!(survey_with_contact, "just a string")
    refute Response.answered_entry?(resp.answers["0"]), "a contact answer is an object or nothing"
  end

  test "the player renders the four fields, the note, and no editor chrome" do
    get play_survey_path(survey_with_contact.publish_token)

    assert_response :success
    Survey::CONTACT_FIELDS.each do |field|
      assert_select ".contact-field[data-contact-key=?]:not([disabled])", field, 1
    end
    assert_select ".contact-note", 1
    assert_select "input.contact-field[type=email][autocomplete=email]", 1
  end

  test "the editor renders the card with disabled fields and the picker offers it" do
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    survey = survey_with_contact(published: false)

    get survey_path(survey)

    assert_response :success
    assert_select ".contact-field[disabled]", 4
    assert_match "Contact details", response.body, "the type picker must offer the new card"
  end

  test "results aggregate contact submissions into a lead table" do
    survey = survey_with_contact
    answer!(survey, { "name" => "Ada", "email" => "ada@example.com" })
    answer!(survey, { "company" => "Acme", "industry" => "Toolmaking" })

    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    get survey_results_path(survey)

    assert_response :success
    assert_match "Ada", response.body
    assert_match "Acme", response.body
  end

  AGG = Class.new do
    include AggregatesSurveyResults
    def build(cards, responses) = aggregate_results(cards, responses)
  end.new

  test "the CSV export formats a contact answer as labelled fields" do
    survey = survey_with_contact
    answer!(survey, { "name" => "Ada", "company" => "Acme", "email" => "ada@example.com" })

    responses = survey.responses.where(status: "completed")
    export = ResultsExport.new(survey: survey, responses: responses,
                               aggregated: AGG.build(Array(survey.cards), responses))
    cell = export.response_rows.flatten.join("\n")
    assert_match "Name: Ada; Company: Acme; Email: ada@example.com", cell
  end

  test "the GDPR respondent-data export includes the contact object" do
    survey = survey_with_contact
    resp = answer!(survey, { "name" => "Ada", "email" => "ada@example.com" })

    export = RespondentDataExport.new(survey: survey, responses: [ resp ]).call
    assert_includes export.to_json, "ada@example.com",
                    "a subject-access export must show every identifying field we hold"
  end

  test "the AI generator never produces a contact card" do
    refute_includes SurveyGenerator::CARD_TYPES, "contact_form",
                    "lead capture is a deliberate creator choice, not something the AI adds"
  end

  test "the AI results digest withholds the identifying fields" do
    survey = survey_with_contact
    answer!(survey, { "name" => "Ada Lovelace", "email" => "ada@example.com" })

    host = Class.new { include AggregatesSurveyResults, FormatsResultsDigest }.new
    aggregated = host.send(:aggregate_results, Array(survey.cards), survey.responses)
    digest = host.send(:results_digest, survey, aggregated, survey.responses.count)

    refute_match "ada@example.com", digest
    refute_match "Lovelace", digest
    assert_match(/contact-detail submissions/, digest)
  end
end
