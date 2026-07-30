require "test_helper"

# The multi-page consent CARD (type "consent_gate"), as opposed to the
# survey-level gate (consent_text) which is a single pseudo-card pinned before
# the deck. Pages are stored exactly like a scenario's, so this inherits that
# type's sanitiser, page-turn widget and id-keyed translations.
class ConsentGateCardTest < ActionDispatch::IntegrationTest
  PAGES = [
    { "id" => "pg_a", "text" => "About this study." },
    { "id" => "pg_b", "text" => "What we do with your answers." }
  ].freeze

  def consent_card(pages: PAGES)
    { "type" => "consent_gate", "pages" => pages.map(&:dup) }
  end

  def setup
    @user = User.create!(name: "U", email_address: "cg-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "cg-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def sign_in!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def survey_with(cards, **attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards, **attrs)
  end

  def published_with(cards, **attrs)
    survey_with(cards, publish_token: SecureRandom.urlsafe_base64(18),
                       published_at: Time.current, **attrs)
  end

  # ── Model / sanitising ────────────────────────────────────────────────────

  test "it is not a question, so it never counts toward grading or progress" do
    assert_not CardTypes.question?("consent_gate")
  end

  # Sanitising happens in Survey.sanitize_cards_images!, which the controller
  # runs over the autosave payload — so these exercise it directly rather than
  # through create!, which doesn't go near it.

  test "pages survive the sanitiser with their ids intact" do
    cards = Survey.sanitize_cards_images!([ { "type" => "welcome_card", "title" => "hi" }, consent_card ])
    pages = cards.last["pages"]
    assert_equal [ "pg_a", "pg_b" ], pages.map { |p| p["id"] }
    assert_equal "About this study.", pages.first["text"]
  end

  test "the page count is capped" do
    pages = Array.new(Survey::MAX_SCENARIO_PAGES + 4) { |i| { "text" => "page #{i}" } }
    kept = Survey.sanitize_cards_images!([ consent_card(pages: pages) ]).first["pages"]
    assert_equal Survey::MAX_SCENARIO_PAGES, kept.size
  end

  test "a page with no id gets one, and blank pages are dropped" do
    pages = [ { "text" => "no id here" }, { "text" => "   " }, { "id" => "pg_z", "text" => "kept" } ]
    kept = Survey.sanitize_cards_images!([ consent_card(pages: pages) ]).first["pages"]

    assert_equal [ "no id here", "kept" ], kept.map { |p| p["text"] }
    assert kept.all? { |p| p["id"].present? }, "a missing id is backfilled so translations can align"
  end

  # Inherited from scenario, and worth stating: the cap is applied to the raw
  # array BEFORE blanks are filtered, so a blank page among the first N costs a
  # slot rather than being skipped over.
  test "the cap counts blank pages before they are dropped" do
    pages = [ { "text" => "   " } ] + Array.new(Survey::MAX_SCENARIO_PAGES) { |i| { "text" => "page #{i}" } }
    kept = Survey.sanitize_cards_images!([ consent_card(pages: pages) ]).first["pages"]
    assert_equal Survey::MAX_SCENARIO_PAGES - 1, kept.size
  end

  test "page text is capped at the same length as a scenario's" do
    long = "x" * (Survey::MAX_SCENARIO_PAGE_LENGTH + 200)
    kept = Survey.sanitize_cards_images!([ consent_card(pages: [ { "text" => long } ]) ]).first["pages"]
    assert_equal Survey::MAX_SCENARIO_PAGE_LENGTH, kept.first["text"].length
  end

  test "translations are re-mapped by page id, so reordering can't scramble them" do
    card = consent_card.merge(
      "i18n" => { "fr" => { "pages" => [ { "id" => "pg_b", "text" => "Ce que nous faisons." },
                                         { "id" => "pg_a", "text" => "À propos." } ] } }
    )
    kept = Survey.sanitize_cards_images!([ card ]).first
    assert_equal [ "pg_b", "pg_a" ], kept["i18n"]["fr"]["pages"].map { |p| p["id"] }
    assert_equal "À propos.", kept["i18n"]["fr"]["pages"].last["text"]
  end

  test "pages are still dropped from card types that do not use them" do
    cards = Survey.sanitize_cards_images!([ { "type" => "yes_no", "text" => "Q", "pages" => PAGES } ])
    assert_nil cards.first["pages"]
  end

  # ── One gate per Verto ────────────────────────────────────────────────────

  test "a consent card switches off the survey-level gate rather than stacking" do
    s = survey_with([ consent_card ], consent_text: "Old single-screen consent.")

    assert s.consent_gate_card?
    assert_not s.consent_required?, "the pseudo-card must stop rendering"
    assert s.consent_gated?, "but consent is still required, by the card"
  end

  test "the survey-level gate still applies when there is no consent card" do
    s = survey_with([ { "type" => "yes_no", "text" => "Q" } ], consent_text: "Agree please.")
    assert s.consent_required?
    assert_not s.consent_gate_card?
  end

  test "the player renders one gate, not two" do
    s = published_with([ consent_card, { "type" => "yes_no", "text" => "Q" } ],
                       consent_text: "Old single-screen consent.")

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-card-type='consent_card']", false, "the pseudo-card must not render"
    assert_select "[data-card-type='consent_gate']"
    assert_no_match "Old single-screen consent.", response.body
  end

  test "the editor stops offering the survey-level gate once a consent card exists" do
    sign_in!
    s = survey_with([ consent_card ])
    get survey_path(s)
    assert_response :success
    assert_select "[data-gate-cards-target='consentCta'][hidden]"
  end

  # ── The snapshot ──────────────────────────────────────────────────────────
  # A response records what the respondent actually agreed to, so the record
  # stays faithful even if the card is edited afterwards.

  test "agreeing snapshots the card's pages, in order" do
    s = published_with([ consent_card, { "type" => "yes_no", "text" => "Q" } ])
    token = SecureRandom.uuid

    post consent_survey_path(s.publish_token),
         params: { session_token: token, agreed: true }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    resp = s.responses.find_by(session_token: token)
    assert resp.consent_agreed_at.present?
    assert_equal "About this study.\n\nWhat we do with your answers.", resp.consent_text_snapshot
  end

  test "declining is recorded, with the same snapshot" do
    s = published_with([ consent_card ])
    token = SecureRandom.uuid

    post consent_survey_path(s.publish_token),
         params: { session_token: token, agreed: false }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    resp = s.responses.find_by(session_token: token)
    assert resp.consent_declined_at.present?
    assert_nil resp.consent_agreed_at
    assert_match "About this study.", resp.consent_text_snapshot
  end

  test "the survey-level gate still snapshots its own text" do
    s = published_with([ { "type" => "yes_no", "text" => "Q" } ], consent_text: "Single screen.")
    token = SecureRandom.uuid

    post consent_survey_path(s.publish_token),
         params: { session_token: token, agreed: true }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    assert_equal "Single screen.", s.responses.find_by(session_token: token).consent_text_snapshot
  end

  # ── Rendering ─────────────────────────────────────────────────────────────

  test "the player renders every page plus an agreement page wired to the gate" do
    s = published_with([ consent_card, { "type" => "yes_no", "text" => "Q" } ])

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-card-type='consent_gate'] .book-page[data-page-id='pg_a']"
    assert_select "[data-card-type='consent_gate'] .book-page[data-page-id='pg_b']"
    assert_select "[data-card-type='consent_gate'] .book-page.is-answer"
    assert_select "[data-card-type='consent_gate'] [data-action='click->player#agreeConsent']"
    assert_select "[data-card-type='consent_gate'] [data-action='click->player#declineConsent']"
    # Read-only pages in the player — the respondent doesn't edit consent.
    assert_select "[data-card-type='consent_gate'] .book-page-text[contenteditable='true']", false
  end

  test "the editor renders editable pages and an inert agreement replica" do
    sign_in!
    s = survey_with([ consent_card ])

    get survey_path(s)
    assert_response :success
    assert_select ".survey-card-wrap[data-card-type='consent_gate'] .book-page-text[contenteditable='true']",
                  count: PAGES.size
    assert_select ".survey-card-wrap[data-card-type='consent_gate'] [data-action='click->scenario#addPage']"
    # The creator must not be able to consent on a respondent's behalf.
    assert_select ".survey-card-wrap[data-card-type='consent_gate'] [data-action*='agreeConsent']", false
  end

  test "it reorders and deletes like any other card" do
    sign_in!
    s = survey_with([ { "type" => "welcome_card", "title" => "hi" }, consent_card ])

    get survey_path(s)
    wrap = ".survey-card-wrap[data-card-type='consent_gate']"
    assert_select "#{wrap} .card-reorder"
    assert_select "#{wrap} .card-delete-btn"
  end

  # ── Answer alignment ──────────────────────────────────────────────────────
  # A consent card occupies a deck index like any other card, which is only safe
  # because cards can't be added to a Verto that already has responses.

  test "a consent card cannot be added to a Verto that has responses" do
    sign_in!
    s = published_with([ { "type" => "yes_no", "text" => "Q" } ])
    s.responses.create!(session_token: SecureRandom.uuid, answers: { "0" => "Yes" },
                        answered: true, status: "completed")

    patch survey_path(s), params: { cards: [ consent_card, { "type" => "yes_no", "text" => "Q" } ] }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :locked
    assert_equal 1, s.reload.cards.size
  end
end
