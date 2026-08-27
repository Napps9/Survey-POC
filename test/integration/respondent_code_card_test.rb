require "test_helper"

# The respondent code as a CARD, and the recall it makes possible.
#
# "Responder codes need a question type: we need a question type so users when a
#  code can type it in and the system connects that user to a responder ID. We
#  also need this feature to be connected to the 'ask once' feature recognising
#  which questions to ask only once."
#
# Both halves existed and neither knew about the other. The code was a
# survey-level PRE-SCREEN pinned before the deck, and it only ever grouped
# responses server-side for wave matching — nothing read it back. "Ask once" was
# enforced entirely in the browser: localStorage keyed to a device-minted uuid,
# so the same person on a new phone was asked everything again, which is the
# opposite of what the setting says.
class RespondentCodeCardTest < ActionDispatch::IntegrationTest
  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "rc-#{suffix}-#{SecureRandom.hex(2)}@test.com",
                        password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "rc-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def deck(recall: true)
    [
      { "type" => "welcome_card",    "cid" => "w",  "text" => "Hello" },
      { "type" => "respondent_code", "cid" => "rc", "text" => "Make up a code",
        "recall" => recall }.compact,
      { "type" => "multiple_choice", "cid" => "q1", "text" => "Industry?",
        "options" => [ "Arts", "Tech" ], "ask_once" => true },
      { "type" => "yes_no",          "cid" => "q2", "text" => "Coming back?", "options" => [ "Yes", "No" ] }
    ]
  end

  def live_survey(org, cards: nil, **attrs)
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: cards || deck,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs
    )
  end

  def body = JSON.parse(response.body)

  # ── The card type ─────────────────────────────────────────────────────────

  test "the card supersedes the survey-level pre-screen rather than doubling it" do
    org = sign_in_org("supersede")
    s = live_survey(org, respondent_code_enabled: true)

    assert s.respondent_code_card?
    assert s.respondent_code_active?, "a code is being collected, which is what the write path asks"
    assert_not s.respondent_code_prescreen?, "asking twice for a code the server records once"

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-card-type=respondent_code_card]", 0, "the pre-screen pseudo-card must be gone"
    assert_select "[data-card-type=respondent_code]", 1
  end

  test "with no card the pre-screen still renders exactly as it did" do
    org = sign_in_org("prescreen")
    s = live_survey(org, cards: deck.reject { |c| c["type"] == "respondent_code" }, respondent_code_enabled: true)

    assert s.respondent_code_prescreen?
    get play_survey_path(s.publish_token)
    assert_select "[data-card-type=respondent_code_card]", 1
  end

  # THE line. apply_respondent_code guarded on the COLUMN, so a deck collecting
  # the code only through a card recorded no digest at all — and wave matching,
  # the returning-respondent count and recall would every one of them have
  # found nothing.
  test "a card-only deck records the digest" do
    org = sign_in_org("digest")
    s = live_survey(org)
    assert_not s.respondent_code_enabled?, "the column is off; only the card is collecting"

    post progress_survey_path(s.publish_token),
         params: { session_token: "rc-1", respondent_code: "sam14",
                   answers: { "2" => { "type" => "multiple_choice", "value" => "Arts" } } },
         as: :json
    assert_response :success

    assert_equal s.respondent_code_digest("sam14"),
                 s.responses.find_by(session_token: "rc-1").respondent_code_digest
  end

  test "a deck may hold only one, and a second is dropped with a warning" do
    org = sign_in_org("single")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: [])

    patch survey_path(s), params: {
      cards: [
        { "type" => "respondent_code", "cid" => "a", "text" => "First" },
        { "type" => "respondent_code", "cid" => "b", "text" => "Second" }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    codes = s.reload.cards.select { |c| c["type"] == "respondent_code" }
    assert_equal 1, codes.size, "apply_respondent_code sets the digest ONCE per response — " \
                                "a second card's answer would be discarded anyway"
    assert_equal "First", codes.first["text"], "the first one keeps its place"
    assert_not CardTypes.pickable_for(s.reload).to_h.key?("respondent_code"),
               "offering a second is offering a card that cannot survive the save"
  end

  test "the recall flag round-trips, and cannot be set on any other card" do
    org = sign_in_org("flag")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: [])

    patch survey_path(s), params: {
      cards: [
        { "type" => "respondent_code", "cid" => "rc", "text" => "Code", "recall" => true },
        { "type" => "yes_no", "cid" => "q", "text" => "Q", "options" => %w[Yes No], "recall" => true }
      ]
    }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal true, s.reload.cards.first["recall"]
    assert_not s.cards.second.key?("recall"),
               "recall is the switch on an endpoint that returns another person's answers — " \
               "only the card that collects the code may carry it"
    assert s.respondent_code_recall?
  end

  test "the editor renders the card and its recall toggle" do
    org = sign_in_org("editor")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: deck)

    get survey_path(s)
    assert_response :success
    assert_select "[data-card-type=respondent_code]", minimum: 1
    assert_select "[data-card-recall=true]", 1
    assert_select "input[data-survey-editor-target=panelRecall]", 1
    assert_match I18n.t("card.recall_ask_once_note"), response.body,
                 "what the creator is agreeing to has to be readable where they decide it"
  end

  test "it is a non-question, so it is not counted, graded or aggregated" do
    assert_not CardTypes.question?("respondent_code")
    assert_includes CardTypes::NON_QUESTION_TYPES, "respondent_code"
    assert_not SurveyGenerator::CARD_TYPES.include?("respondent_code"),
               "the AI must not invent an identity card for a creator"
  end

  # ── Recall ────────────────────────────────────────────────────────────────

  def seed_prior_run(survey, code:, answers:)
    survey.responses.create!(
      session_token: "prior-#{SecureRandom.hex(3)}", status: "completed", answered: true,
      completed_at: Time.current, answers: answers,
      respondent_code_digest: survey.respondent_code_digest(code)
    )
  end

  test "a returning respondent's ask-once answer comes back, on any device" do
    org = sign_in_org("recall")
    s = live_survey(org)
    seed_prior_run(s, code: "sam14", answers: { "2" => { "type" => "multiple_choice", "value" => "Arts" } })

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_response :success
    assert_equal({ "type" => "multiple_choice", "value" => "Arts" }, body["answers"]["q1"],
                 "keyed by cid — the identity the rest of the codebase uses")
  end

  test "recall is off unless the creator turned it on" do
    org = sign_in_org("optin")
    s = live_survey(org, cards: deck(recall: false))
    seed_prior_run(s, code: "sam14", answers: { "2" => { "type" => "multiple_choice", "value" => "Arts" } })

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_equal({}, body["answers"], "the default has to be the safe one")
  end

  test "only ask-once cards come back, never the rest of the response" do
    org = sign_in_org("scope")
    s = live_survey(org)
    seed_prior_run(s, code: "sam14", answers: {
      "2" => { "type" => "multiple_choice", "value" => "Arts" },
      "3" => { "type" => "yes_no", "value" => "Yes" }
    })

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_equal %w[q1], body["answers"].keys, "q2 is not ask-once, so it is not this endpoint's business"
  end

  test "untoggling ask-once stops recall for that card immediately" do
    org = sign_in_org("untoggle")
    s = live_survey(org)
    seed_prior_run(s, code: "sam14", answers: { "2" => { "type" => "multiple_choice", "value" => "Arts" } })

    cards = s.cards.map { |c| c["cid"] == "q1" ? c.except("ask_once") : c }
    s.update!(cards: cards)

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_equal({}, body["answers"], "read from the deck as it is NOW — no migration, no backfill")
  end

  test "a graded or token-awarding card is never recalled" do
    org = sign_in_org("graded")
    cards = deck
    cards[2] = cards[2].merge("correct" => "Arts")
    s = live_survey(org, cards: cards, quiz: true)
    seed_prior_run(s, code: "sam14", answers: { "2" => { "type" => "multiple_choice", "value" => "Arts" } })

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_equal({}, body["answers"],
                 "handing back a mark for a question this run didn't answer — which locked_merge " \
                 "then commits as immutable — is a scoring hole, not a convenience")
  end

  # The code is chosen to be memorable, so two people can invent "sam14".
  # Nothing has ever stopped them; until recall the only cost was a slightly
  # wrong returning-respondent count.
  test "a card whose stored answers disagree under one code is dropped" do
    org = sign_in_org("collide")
    s = live_survey(org)
    seed_prior_run(s, code: "sam14", answers: { "2" => { "type" => "multiple_choice", "value" => "Arts" } })
    seed_prior_run(s, code: "sam14", answers: { "2" => { "type" => "multiple_choice", "value" => "Tech" } })

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_equal({}, body["answers"],
                 "failing toward asking the question again is the recoverable direction")
  end

  test "an unknown code, a blank one and a known one with nothing look identical" do
    org = sign_in_org("uniform")
    s = live_survey(org)

    [ "nobody-has-this", "", nil ].each do |code|
      post recall_survey_path(s.publish_token), params: { respondent_code: code }, as: :json
      assert_response :success
      assert_equal({ "ok" => true, "answers" => {} }, body,
                   "an endpoint that distinguishes 'no such code' from 'that code has nothing' " \
                   "is an endpoint that confirms codes")
    end
  end

  test "the code never reaches the response body" do
    org = sign_in_org("leak")
    s = live_survey(org)
    seed_prior_run(s, code: "sam14", answers: { "2" => { "type" => "multiple_choice", "value" => "Arts" } })

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_not_includes response.body, "sam14"
    assert_not_includes response.body, s.respondent_code_digest("sam14")
  end

  test "a closed Verto recalls nothing" do
    org = sign_in_org("closed")
    s = live_survey(org)
    s.update!(unpublished_at: Time.current)

    post recall_survey_path(s.publish_token), params: { respondent_code: "sam14" }, as: :json
    assert_response :gone
  end

  # Owner preview and Test Mode must never be able to read a real respondent's
  # answers back — the same rule grade_url and scores_url already follow.
  test "the player page carries no recall URL in preview or with recall off" do
    org = sign_in_org("urls")
    s = live_survey(org)

    get play_survey_path(s.publish_token)
    assert_match 'data-player-recall-url-value="' + recall_survey_url(s.publish_token) + '"', response.body

    s.update!(cards: deck(recall: false))
    get play_survey_path(s.publish_token)
    assert_match 'data-player-recall-url-value=""', response.body
  end
end
