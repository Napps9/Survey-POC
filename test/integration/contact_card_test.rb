require "test_helper"

# The contact card (`contact_form`) was the one card type that collected
# identifying respondent data. It is now RETIRED, and retirement has a contract
# of its own, pinned here end to end.
#
# Two halves, and the second is the one that is easy to get wrong:
#
#   Nothing more is collected — the type isn't offered, can't be saved onto a
#   deck, isn't rendered to a respondent, and an answer posted to the public
#   JSON endpoint anyway is refused.
#
#   Nothing already collected is lost or misaligned — a live deck KEEPS its
#   card, because answers are keyed by card index and pulling one out would
#   re-point every answer stored after it. The player skips the card without
#   renumbering the rest, and results / CSV / subject-access exports still show
#   the details gathered while it was live.
class ContactCardTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "Leads", slug: "leads-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "lead-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
  end

  # A deck built before the retirement: written straight to the column, the way
  # one already sitting in the database looks. The editor's save path is what
  # drops these (see the save test below), and it never ran on this one.
  def survey_with_contact(published: true, trailing_card: false)
    cards = [ { "type" => "contact_form", "cid" => "cf1", "text" => "Stay in touch?" } ]
    if trailing_card
      cards << { "type" => "open_ended", "cid" => "q2", "text" => "Anything else?" }
    end
    s = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards
    )
    s.update!(publish_token: SecureRandom.hex(8)) if published
    s
  end

  def answer!(survey, value, key: "0", type: "contact_form")
    post progress_survey_path(survey.publish_token),
         params: { answers: { key => { "type" => type, "value" => value } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    survey.responses.order(:id).last.tap { |r| r.update!(status: "completed") }
  end

  def login!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  # ── Nothing more is collected ──────────────────────────────────────────────

  test "the type is retired, and retired types are never pickable" do
    assert CardTypes.retired?("contact_form")
    refute_includes CardTypes.pickable.map(&:first), "contact_form"
    CardTypes.all.each do |key, _attrs|
      refute CardTypes.retired?(key) && CardTypes.pickable.map(&:first).include?(key),
             "#{key} is both retired and pickable"
    end
  end

  test "the editor no longer offers the card" do
    login!
    get survey_path(survey_with_contact(published: false))

    assert_response :success
    assert_select ".type-opt[data-type='contact_form']", 0
    assert_select ".aq-type-tile[data-type='contact_form']", 0
  end

  test "a save that sends a contact card drops it, with a warning" do
    login!
    survey = @org.surveys.create!(title: "S", theme: "Sports", audience_age: "all",
                                  key_insight: "x", default_locale: "en", locales: [ "en" ],
                                  cards: [ { "type" => "open_ended", "cid" => "q1", "text" => "Hi?" } ])

    patch survey_path(survey),
          params: { cards: [ { "type" => "open_ended", "cid" => "q1", "text" => "Hi?" },
                             { "type" => "contact_form", "cid" => "sneaky", "text" => "Details?" } ] }.to_json,
          headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :success
    assert_includes JSON.parse(response.body)["warnings"], "retired_card"
    assert_equal [ "open_ended" ], survey.reload.cards.map { |c| c["type"] }
  end

  test "the player skips a legacy contact card without renumbering the others" do
    survey = survey_with_contact(trailing_card: true)

    get play_survey_path(survey.publish_token)

    assert_response :success
    assert_select ".contact-field", 0
    assert_select "[data-card-index='0']", 0, "the retired card must not be rendered"
    # The card AFTER it keeps index 1 — its position in @survey.cards, which is
    # the key its answer is stored under. Sliding it up to 0 would re-point
    # every answer already collected for this Verto.
    assert_select "[data-card-index='1'][data-card-type='open_ended']", 1
  end

  test "the public endpoint refuses an answer to a retired card" do
    resp = answer!(survey_with_contact, { "name" => "Ada", "email" => "ada@example.com" })

    assert_nil resp.answers["0"]["value"],
               "a cached player, or a hand-rolled POST, must not be able to keep collecting"
    refute Response.answered_entry?(resp.answers["0"])
  end

  test "refusing a retired answer leaves every other answer alone" do
    survey = survey_with_contact(trailing_card: true)
    post progress_survey_path(survey.publish_token),
         params: { answers: {
           "0" => { "type" => "contact_form", "value" => { "name" => "Ada" } },
           "1" => { "type" => "open_ended", "value" => "Nothing else, thanks" }
         } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    answers = survey.responses.order(:id).last.answers
    assert_nil answers["0"]["value"]
    assert_equal "Nothing else, thanks", answers["1"]["value"]
  end

  test "the AI generator never produces a contact card" do
    refute_includes SurveyGenerator::CARD_TYPES, "contact_form",
                    "a retired type is not something the AI can reintroduce"
  end

  # ── Nothing already collected is lost ──────────────────────────────────────

  # Details gathered while the card was live, written the way the player wrote
  # them then. Retiring the card stopped the collection; it did not delete this.
  def survey_with_legacy_leads
    survey = survey_with_contact
    [ { "name" => "Ada", "company" => "Acme", "email" => "ada@example.com" },
      { "company" => "Analytical Engines", "industry" => "Toolmaking" } ].each do |value|
      survey.responses.create!(status: "completed", session_token: SecureRandom.uuid,
                               answers: { "0" => { "type" => "contact_form", "value" => value } })
    end
    survey
  end

  test "results still show the details collected while the card was live" do
    survey = survey_with_legacy_leads

    login!
    get survey_results_path(survey)

    assert_response :success
    assert_match "Ada", response.body
    assert_match "Analytical Engines", response.body
  end

  AGG = Class.new do
    include AggregatesSurveyResults
    def build(cards, responses) = aggregate_results(cards, responses)
  end.new

  test "the CSV export still formats a stored contact answer as labelled fields" do
    survey = survey_with_legacy_leads

    responses = survey.responses.where(status: "completed")
    export = ResultsExport.new(survey: survey, responses: responses,
                               aggregated: AGG.build(Array(survey.cards), responses))
    cell = export.response_rows.flatten.join("\n")
    assert_match "Name: Ada; Company: Acme; Email: ada@example.com", cell
  end

  test "the GDPR respondent-data export still includes the stored contact object" do
    survey = survey_with_legacy_leads

    export = RespondentDataExport.new(survey: survey, responses: survey.responses.to_a).call
    assert_includes export.to_json, "ada@example.com",
                    "a subject-access export must show every identifying field we still hold"
  end

  test "the AI results digest still withholds the identifying fields" do
    survey = survey_with_legacy_leads

    host = Class.new { include AggregatesSurveyResults, FormatsResultsDigest }.new
    aggregated = host.send(:aggregate_results, Array(survey.cards), survey.responses)
    digest = host.send(:results_digest, survey, aggregated, survey.responses.count)

    refute_match "ada@example.com", digest
    refute_match(/\bAda\b/, digest)
    assert_match(/contact-detail submissions/, digest)
  end
end
