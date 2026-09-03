require "test_helper"

# The editing lock (Survey#editing_locked?) freezes a live or answered deck for
# everyone — except the accounts LiveEditAccess names, who may edit it anyway.
# The owner asked for this for their own account (2026-09-02).
#
# These tests pin down what the override IS (the server accepts every content
# mutation it would otherwise 423, and the editor renders as it does for a
# draft, plus a warning) and, just as much, what it is NOT: it is a property of
# the account, not of the organisation or the Verto; it is an allowlist the
# environment can narrow to nobody; and it never reaches into the model's own
# guards, so the primary-language switch stays locked.
class LiveEditOverrideTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  def setup
    @original_env = ENV["LIVE_EDIT_USER_EMAILS"]
    ENV.delete("LIVE_EDIT_USER_EMAILS") # the default: the owner's address

    @org   = Organisation.create!(name: "O", slug: "le-#{SecureRandom.hex(3)}")
    @owner = User.create!(name: "Nick", email_address: LiveEditAccess::DEFAULT_EMAILS,
                          password: "verylongpassword")
    @owner.verify_email! # the address is the credential, so it has to be a proven one
    @org.memberships.create!(user: @owner, role: "admin")
    # Same organisation, same role — everything about this account is equal to
    # the owner's except its address, which is what proves the override is an
    # account property and not an org or role one.
    @member = User.create!(name: "Member", email_address: "le-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    @org.memberships.create!(user: @member, role: "admin")

    # logic: on, so the flow panel (whose actions the lock hides) is rendered.
    @live = @org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "x",
                                 default_locale: "en", locales: [ "en", "fr" ], cards: CARDS.map(&:dup),
                                 logic: true,
                                 publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    @live.responses.create!(session_token: SecureRandom.uuid, answers: { "1" => "Yes" },
                            answered: true, status: "completed")
    @draft = @org.surveys.create!(title: "Draft", theme: "Draft", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup))
  end

  def teardown
    if @original_env.nil?
      ENV.delete("LIVE_EDIT_USER_EMAILS")
    else
      ENV["LIVE_EDIT_USER_EMAILS"] = @original_env
    end
  end

  def sign_in(user)
    delete session_path
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def patch_cards(survey, text)
    patch survey_path(survey),
          params: { cards: [ { "type" => "open_ended", "text" => text } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
  end

  def edit_bar     = I18n.t("editor.live_edit_bar")
  def edit_warning = I18n.t("editor.live_edit_warning")
  def lock_bar     = I18n.t("editor.live_locked_bar")

  # ── The override ──────────────────────────────────────────────────────────

  test "the allowed account saves a deck edit to a live Verto that has responses" do
    sign_in @owner
    assert @live.editing_locked?, "precondition: the Verto is locked for everyone else"

    assert_no_difference "Response.count" do
      patch_cards(@live, "edited while live")
    end
    assert_response :success
    assert_equal "edited while live", @live.reload.cards.first["text"]
    assert @live.published?, "editing never touches the publish state"
  end

  test "the allowed account gets past every content endpoint that would otherwise 423" do
    sign_in @owner

    post render_survey_card_path(@live), params: { "type" => "yes_no", "text" => "x" }.to_json,
                                         headers: { "Content-Type" => "application/json" }
    assert_response :success
    assert JSON.parse(response.body)["ok"]

    # SETTINGS_LOCKED_IN_USE — the scoring switches and consent — open up too.
    post survey_settings_path(@live), params: { quiz: "1" }
    assert @live.reload.quiz?

    post survey_settings_path(@live), params: { consent_text: "Amended while live." }, as: :json
    assert_response :success
    assert_equal "Amended while live.", @live.reload.consent_text

    # The remaining guards, each hit with a payload that fails LATER for its
    # own reason (no such card, junk image, junk URL): the point is that none
    # of them answers 423 any more. The AI endpoints are covered by the
    # generate_flow hand-off, which enqueues rather than calling Claude.
    json = { "Content-Type" => "application/json", "Accept" => "application/json" }
    post restore_survey_card_path(@live), params: { cid: "c_nope" }.to_json, headers: json
    assert_response :not_found, "no such card in the bin — the endpoint's own answer, not the lock's"
    post card_image_survey_path(@live), params: { image: "not-an-image" }.to_json, headers: json
    assert_response :unprocessable_content
    post card_lottie_survey_path(@live), params: { url: "https://example.com/not-lottie" }.to_json, headers: json
    assert_response :unprocessable_content
    post demographic_survey_card_path(@live, key: "heritage")
    assert_not_equal 423, response.status
    post generate_survey_flow_path(@live), params: { prompt: "Ask the UK audience about local pitches" }.to_json, headers: json
    assert_response :success
    assert JSON.parse(response.body)["ok"]
  end

  test "a closed Verto (taken down after collecting responses) opens up for the allowed account as well" do
    @live.update!(unpublished_at: Time.current)
    assert @live.closed?
    sign_in @owner

    patch_cards(@live, "edited while closed")
    assert_response :success
    assert_equal "edited while closed", @live.reload.cards.first["text"]

    # …and the editor warns about it the same way: the bar and modal key on
    # editing_locked?, not published?, so a closed deck gets them too.
    get survey_path(@live)
    assert_response :success
    assert_select "[data-live-edit-bar]", count: 1
    assert_includes response.body, ERB::Util.html_escape(edit_warning)
    refute_match "editor-feed-locked", response.body
    assert_match "your account can still edit the questions", response.body,
                 "the Status panel must not go on saying the questions stay locked"
  end

  # A locked deck saved under the override keeps its SHAPE. The sanitiser's
  # tail moves a consent gate ahead of the first question and drops retired
  # cards; on a draft that is housekeeping, on a deck with stored answers it
  # would re-point them behind the editor's promise that fixing wording in
  # place is safe. Historical live decks are exactly where those shapes exist.
  test "saving a live deck keeps its existing shape: an out-of-place consent gate stays put" do
    cards = [
      { "type" => "welcome_card", "title" => "hi" },
      { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ] },
      { "type" => "consent_gate", "text" => "Agree?" }
    ]
    @live.update_columns(cards: cards) # as stored, bypassing every normaliser
    sign_in @owner

    edited = cards.map(&:dup)
    edited[1] = edited[1].merge("text" => "Like sport a lot?")
    patch survey_path(@live), params: { cards: edited }.to_json,
                              headers: { "Content-Type" => "application/json" }
    assert_response :success
    assert_equal %w[welcome_card yes_no consent_gate], @live.reload.cards.map { |c| c["type"] },
                 "the gate must stay where the stored answers expect it"
    assert_equal "Like sport a lot?", @live.cards[1]["text"], "the wording fix itself lands"

    # The same save on a draft is still normalised — the gate moves ahead.
    @draft.update_columns(cards: cards)
    patch survey_path(@draft), params: { cards: cards }.to_json,
                               headers: { "Content-Type" => "application/json" }
    assert_response :success
    assert_equal %w[welcome_card consent_gate yes_no], @draft.reload.cards.map { |c| c["type"] }
  end

  test "the editor renders editable for the allowed account, with the live-edit warning instead of the lock" do
    sign_in @owner
    get survey_path(@live)
    assert_response :success

    # The lock is gone: client-side switches, feed, chrome, title.
    assert_match 'data-survey-editor-live-value="false"', response.body
    assert_match 'data-journey-editable-value="true"', response.body
    refute_match "editor-feed-locked", response.body
    assert_match "add-question#open", response.body, "add-question trigger is back"
    assert_match "shuffle_assets", response.body, "shuffle is back"
    assert_match "card-move-btn", response.body, "reorder is back"
    assert_match "card-duplicate-btn", response.body, "duplicate is back"
    assert_match "flows#newFlow", response.body, "the flow panel's actions are back"
    assert_select "[data-flows-target='modal']", { count: 1 },
                  "the Generate button's modal is rendered too — a button that opens nothing is a dead click"
    assert_select "[data-survey-editor-target='vertoTitle'][contenteditable='true']"
    assert_select "input[name='quiz'][disabled]", count: 0
    assert_select "input[name='tokenisation_enabled'][disabled]", count: 0
    # The phone chrome unlocks with it.
    assert_select "[data-action*='mobile-studio#addAfterActive']", count: 1
    assert_select "[data-mobile-studio-target='titleText'][contenteditable='true']", count: 1

    # …and the warning is there in its place.
    assert_select "[data-live-edit-bar]", count: 1
    assert_includes response.body, ERB::Util.html_escape(edit_bar)
    assert_includes response.body, ERB::Util.html_escape(edit_warning)
    assert_not_includes response.body, ERB::Util.html_escape(lock_bar)
    assert_not_includes response.body, ERB::Util.html_escape(I18n.t("editor.live_warning"))
  end

  test "a draft shows neither the lock nor the live-edit warning to the allowed account" do
    sign_in @owner
    get survey_path(@draft)
    assert_response :success

    assert_select "[data-live-edit-bar]", count: 0
    assert_not_includes response.body, ERB::Util.html_escape(edit_bar)
    assert_not_includes response.body, ERB::Util.html_escape(lock_bar)
    assert_match "add-question#open", response.body
  end

  # ── What it is not ────────────────────────────────────────────────────────

  test "an equal member of the same organisation is still locked out" do
    sign_in @member

    patch_cards(@live, "sneaky edit")
    assert_response :locked
    assert_equal "Like sport?", @live.reload.cards.last["text"], "cards must be untouched"

    post survey_settings_path(@live), params: { quiz: "1" }
    assert_not @live.reload.quiz?

    get survey_path(@live)
    assert_response :success
    assert_match "editor-feed-locked", response.body
    assert_match 'data-survey-editor-live-value="true"', response.body
    assert_select "[data-flows-target='modal']", count: 0
    assert_select "[data-action*='mobile-studio#addAfterActive']", count: 0
    assert_select "[data-mobile-studio-target='titleText'][contenteditable='true']", count: 0
    assert_select "[data-live-edit-bar]", count: 0
    assert_includes response.body, ERB::Util.html_escape(lock_bar)
    assert_not_includes response.body, ERB::Util.html_escape(edit_bar)
  end

  test "the allowlist is the environment's when set: blank switches the owner off, a listed member is let in" do
    ENV["LIVE_EDIT_USER_EMAILS"] = ""
    sign_in @owner
    patch_cards(@live, "no longer allowed")
    assert_response :locked
    get survey_path(@live)
    assert_match "editor-feed-locked", response.body

    ENV["LIVE_EDIT_USER_EMAILS"] = "someone@else.com, #{@member.email_address.upcase}"
    sign_in @member
    patch_cards(@live, "not until verified")
    assert_response :locked, "a listed address that hasn't proven its mailbox is still locked out"

    @member.verify_email!
    patch_cards(@live, "now allowed")
    assert_response :success
    assert_equal "now allowed", @live.reload.cards.first["text"]
  end

  test "the override never reaches the model: the primary language stays locked" do
    sign_in @owner

    get survey_path(@live)
    assert_select "select[name='default_locale'][disabled]", { count: 1 },
                  "the switch would only bounce, so it is not offered"

    post survey_languages_path(@live), params: { default_locale: "fr" }
    assert_redirected_to survey_path(@live, panel: "publish", language_error: "primary")
    assert_equal "en", @live.reload.default_locale
  end

  test "the override is not a door into another organisation's Vertos" do
    other = Organisation.create!(name: "Elsewhere", slug: "le-other-#{SecureRandom.hex(3)}")
    theirs = other.surveys.create!(title: "Theirs", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                   publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    sign_in @owner

    # Scoped through Current.organisation.surveys, exactly as before: the Verto
    # is simply not found (#update's blanket rescue reports that as a 422, but
    # the property that matters is that nothing was saved).
    patch_cards(theirs, "reaching across")
    assert_not response.successful?
    assert_equal "Like sport?", theirs.reload.cards.last["text"]
  end
end
