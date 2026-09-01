require "test_helper"

# BUG-028. Declining consent stamped `consent_declined_at` and did nothing else.
#
# A consent gate is an ordinary deck card, so it could sit at position four —
# and `/progress` persists answers on every advance. By the time a respondent
# read the sheet and tapped "No thanks", their earlier answers were already
# stored, already counted as a responder, and already feeding the creator's
# results and the public /results and /regions aggregates. The creator's
# respondent-data screen only renders "agreed"/"none", so a declined respondent
# looked like someone who had never been asked — while their data sat there.
#
# Two changes, per the owner's decision: the gate is now hoisted ahead of the
# first question on save so the situation cannot arise on a deck built from now
# on, and declining purges what was collected while keeping the decline itself
# on record.
class ConsentDeclinePurgeTest < ActionDispatch::IntegrationTest
  # A gate at position 3 — what a deck saved before the hoist looks like.
  CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "multiple_choice", "cid" => "q1", "text" => "Where do you live?",
      "options" => [ "North", "South" ] },
    { "type" => "yes_no", "cid" => "q2", "text" => "Feel safe?", "options" => %w[Yes No] },
    { "type" => "consent_gate", "cid" => "cg", "text" => "Before you go on",
      "pages" => [ { "id" => "p1", "text" => "Here is what we will do with your answers." } ] },
    { "type" => "yes_no", "cid" => "q3", "text" => "One more?", "options" => %w[Yes No] }
  ].freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "cd-#{SecureRandom.hex(3)}")
    # update_columns so the deck keeps its mid-deck gate — the shape a Verto
    # saved before the hoist has, and the one this purge exists to cover.
    @survey = @org.surveys.create!(
      title: "Consent", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: [ { "type" => "welcome_card", "title" => "Hi" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current,
      show_results_comparison: true
    )
    @survey.update_columns(cards: CARDS)
    @token = SecureRandom.uuid
  end

  def answer_first_questions
    post progress_survey_path(@survey.publish_token),
         params: { session_token: @token,
                   answers: { "1" => { "type" => "multiple_choice", "value" => "North" },
                              "2" => { "type" => "yes_no", "value" => "Yes" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  def decline
    post consent_survey_path(@survey.publish_token),
         params: { session_token: @token, agreed: false }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
  end

  def response_row = @survey.reload.responses.find_by(session_token: @token)

  test "answers given before the gate are stored, then purged on decline" do
    answer_first_questions
    assert response_row.answers.present?, "precondition: the answers reach the server before the gate"
    assert response_row.answered?

    decline
    assert_response :success

    row = response_row
    assert_empty row.answers, "declining must discard what was already collected"
    refute row.answered?, "a declined respondent must not count as a responder"
  end

  test "the decline itself stays on record" do
    answer_first_questions
    decline

    row = response_row
    assert row.consent_declined_at.present?, "the decline is the evidence it was honoured"
    assert row.consent_text_snapshot.present?, "and what they were shown when they declined"
    assert_equal @token, row.session_token
  end

  test "the denormalised region and demographic copies go too" do
    # These are extracted from the answers on save, so purging `answers` alone
    # would leave the personal data behind in its own columns — exactly what the
    # gate exists to prevent.
    post progress_survey_path(@survey.publish_token),
         params: { session_token: @token,
                   answers: { "1" => { "type" => "location", "value" => "North" },
                              "2" => { "type" => "demographic_gender", "value" => "female" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    decline

    row = response_row
    assert_nil row.region_country
    assert_nil row.region_label
    assert_nil row.demographic_gender
    assert_nil row.demographic_birth_year
    assert_nil row.demographic_heritage
    assert_nil row.demographic_neurodiversity
    assert_nil row.respondent_code_digest
  end

  test "a declined respondent is out of the public aggregates" do
    answer_first_questions
    decline

    get player_results_path(@survey.publish_token)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 0, body["total"].to_i,
                 "the public results must not include someone who refused consent"
  end

  # The negative case. Agreeing must leave everything exactly as it was, or the
  # purge would be eating every respondent's answers.
  test "agreeing changes nothing about the answers" do
    answer_first_questions

    post consent_survey_path(@survey.publish_token),
         params: { session_token: @token, agreed: true }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    row = response_row
    assert_equal "North", row.answers.dig("1", "value")
    assert row.answered?
    assert row.consent_agreed_at.present?
    assert_nil row.consent_declined_at
  end


  # ── Decline is terminal (review findings) ────────────────────────────────
  #
  # The purge alone only held for an instant: nothing read consent_declined_at
  # afterwards, so any later write with the same token — an in-flight
  # /progress, a queued replay, a crafted POST — re-stored everything and
  # re-counted the respondent, while the row still said they had declined.

  test "a write after the decline is refused and the row stays purged" do
    answer_first_questions
    decline

    post progress_survey_path(@survey.publish_token),
         params: { session_token: @token,
                   answers: { "1" => { "type" => "multiple_choice", "value" => "North" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :forbidden

    row = response_row
    assert_empty row.answers, "a post-decline write re-populated the purged response"
    refute row.answered?
  end

  test "a submit after the decline is refused too" do
    answer_first_questions
    decline

    post submit_survey_path(@survey.publish_token),
         params: { session_token: @token,
                   answers: { "1" => { "type" => "multiple_choice", "value" => "South" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :forbidden
    assert_empty response_row.answers
  end

  test "an explicit re-agree clears the decline and reopens the session" do
    # A mis-tap on "No thanks" must not strand the respondent forever — but the
    # record has to say ONE thing, so the agree replaces the decline rather
    # than standing beside it.
    answer_first_questions
    decline

    post consent_survey_path(@survey.publish_token),
         params: { session_token: @token, agreed: true }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    row = response_row
    assert row.consent_agreed_at.present?
    assert_nil row.consent_declined_at, "both timestamps standing is an uninterpretable audit row"

    post progress_survey_path(@survey.publish_token),
         params: { session_token: @token,
                   answers: { "1" => { "type" => "multiple_choice", "value" => "North" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal "North", response_row.answers.dig("1", "value")
  end

  test "the purge broadcasts, so a live results screen sees the numbers drop" do
    broadcasts = []
    answer_first_questions

    stub_method(ResultsActivity, :broadcast, ->(survey) { broadcasts << survey.id }) do
      decline
      # The transition schedules a coalesced BroadcastResultsActivityJob; the
      # broadcast itself happens when the job performs.
      drain_enqueued_jobs
    end

    assert_includes broadcasts, @survey.id,
                    "answered flipping true→false is the one transition where live " \
                    "results must go DOWN — it used to be the one that never broadcast"
  end

  # ── The consent URL is no longer a lever on other surveys' data ──────────

  test "another survey's consent URL cannot purge this response" do
    answer_first_questions

    other = @org.surveys.create!(
      title: "Other", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "oq", "text" => "Q?", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )

    post consent_survey_path(other.publish_token),
         params: { session_token: @token, agreed: false }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :forbidden

    row = response_row
    assert row.answers.present?, "a crafted cross-survey consent POST purged the response"
    assert_nil row.consent_declined_at
    assert_equal 0, other.reload.responses.count, "and no phantom row on the other survey"
  end

  # ── The rescue split (review finding: transient faults looked permanent) ─

  test "a malformed body is a 400, not something to retry" do
    # text/plain, deliberately: with a JSON content type the framework's params
    # parser raises before the action runs (which production maps to a 400 of
    # its own). A malformed body WITHOUT that content type reaches the action's
    # own JSON.parse — the path this rescue exists for.
    post submit_survey_path(@survey.publish_token),
         params: "{not json",
         headers: { "CONTENT_TYPE" => "text/plain" }
    assert_response :bad_request
  end

  test "an unexpected server fault is a 500, so the service worker retries it" do
    # As a 422 this was final: the worker drops 4xx, and the respondent was
    # told the Verto had closed — for a fault a retry seconds later survives.
    stub_method(SupportedLocales, :coerce, ->(*) { raise "transient burp" }) do
      post submit_survey_path(@survey.publish_token),
           params: { session_token: @token, locale: "fr",
                     answers: { "1" => { "type" => "multiple_choice", "value" => "North" } } }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
    end
    assert_response :internal_server_error
  end

  # ── The hoist ────────────────────────────────────────────────────────────

  test "a consent gate is moved ahead of the first question on save" do
    deck = Survey.sanitize_cards_images!(CARDS.map(&:dup), warnings: [])
    assert_equal %w[welcome_card consent_gate multiple_choice yes_no yes_no],
                 deck.map { |c| c["type"] }
  end

  test "non-question cards may still come first" do
    # "Hello → consent → questions" is a better flow than consent-first, and it
    # is still safe: a welcome card captures nothing.
    deck = Survey.sanitize_cards_images!(CARDS.map(&:dup), warnings: [])
    assert_equal "welcome_card", deck.first["type"]
  end

  test "a gate that is already in front is left alone" do
    already = [ { "type" => "consent_gate", "cid" => "cg", "text" => "First",
                  "pages" => [ { "id" => "p", "text" => "Please read." } ] },
                { "type" => "yes_no", "cid" => "q", "text" => "Q?", "options" => %w[Yes No] } ]
    deck = Survey.sanitize_cards_images!(already, warnings: [])
    assert_equal %w[consent_gate yes_no], deck.map { |c| c["type"] }
  end

  test "a hoisted gate loses its flow membership and next pointer" do
    # FlowCompiler runs after the hoist and chains flow members in DECK order,
    # so a hoisted gate that kept its flow_id became the flow's first member —
    # and its compiled `next` jumped respondents straight back to where the
    # gate used to sit, silently skipping every question in between.
    deck = [
      { "type" => "yes_no", "cid" => "q1", "text" => "Q1?", "options" => %w[Yes No] },
      { "type" => "yes_no", "cid" => "q2", "text" => "Q2?", "options" => %w[Yes No] },
      { "type" => "consent_gate", "cid" => "cg", "text" => "Consent",
        "flow_id" => "f_abc", "next" => { "card" => "q9" }, "lane_label" => "Branch",
        "pages" => [ { "id" => "p", "text" => "Please read." } ] }
    ]
    warnings = []
    out = Survey.sanitize_cards_images!(deck, warnings: warnings)

    gate = out.find { |c| c["type"] == "consent_gate" }
    assert_equal "consent_gate", out.first["type"], "the gate should be hoisted"
    refute gate.key?("flow_id"), "flow membership must not travel with the hoist"
    refute gate.key?("next"), "a stale next pointer at the front skips questions"
    refute gate.key?("lane_label")
    assert_includes warnings, "consent_gate_moved",
                    "the editor's DOM still shows the old order — the move must be reported"
  end

  test "a gate already in place keeps its routing untouched" do
    # The strip is part of MOVING the gate. A gate that already sits ahead of
    # the questions is in a position its routing was authored for.
    deck = [
      { "type" => "consent_gate", "cid" => "cg", "text" => "Consent",
        "next" => { "card" => "q2" }, "pages" => [ { "id" => "p", "text" => "Read." } ] },
      { "type" => "yes_no", "cid" => "q1", "text" => "Q1?", "options" => %w[Yes No] },
      { "type" => "yes_no", "cid" => "q2", "text" => "Q2?", "options" => %w[Yes No] }
    ]
    warnings = []
    out = Survey.sanitize_cards_images!(deck, warnings: warnings)
    assert_equal({ "card" => "q2" }, out.first["next"])
    refute_includes warnings, "consent_gate_moved"
  end

  test "a deck with no gate is untouched" do
    plain = [ { "type" => "welcome_card", "title" => "Hi" },
              { "type" => "yes_no", "cid" => "q", "text" => "Q?", "options" => %w[Yes No] } ]
    deck = Survey.sanitize_cards_images!(plain, warnings: [])
    assert_equal %w[welcome_card yes_no], deck.map { |c| c["type"] }
  end
end
