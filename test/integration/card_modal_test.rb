require "test_helper"

# The card intro modal, end to end through the two pages that render it: the
# public player (where a respondent meets it) and the editor (where a creator
# writes it). The model contract is covered by SurveyCardModalTest; this is
# about what actually reaches the two HTML documents.
class CardModalTest < ActionDispatch::IntegrationTest
  def plain_card
    { "type" => "yes_no", "cid" => "c_plain", "text" => "Did you use it?",
      "options" => %w[Yes No] }
  end

  def modal_card
    { "type" => "select_many", "cid" => "c_modal", "text" => "Which have you used?",
      "options" => [ "A food bank", "A debt adviser" ],
      "modal_title" => "Before you answer this one",
      "modal_body" => "We mean services you used yourself." }
  end

  def setup
    @user = User.create!(name: "U", email_address: "cm-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "cm-#{SecureRandom.hex(3)}")
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

  # ── Player ────────────────────────────────────────────────────────────────

  test "the modal is rendered, hidden, on the card that carries one" do
    s = published_with([ plain_card, modal_card ])
    get play_survey_path(s.publish_token)

    assert_response :success
    assert_select "[data-card-cid='c_modal'][data-card-modal='true']", 1
    assert_select "[data-card-cid='c_plain'][data-card-modal]", 0,
                  "a card with no modal must not claim one"
    assert_select "[data-role='card-modal'][hidden]", 1,
                  "server-rendered but shut — the player opens it on arrival"
    assert_match "Before you answer this one", response.body
    assert_match "We mean services you used yourself.", response.body
  end

  test "the dismiss button is platform copy in the respondent's own language" do
    s = published_with([ modal_card ], locales: %w[en fr])
    get play_survey_path(s.publish_token), params: { lang: "fr" }

    assert_response :success
    assert_select ".card-modal-cta", text: I18n.t("player.modal_continue", locale: :fr)
  end

  test "a creator's words are translated; an untranslated modal falls back" do
    card = modal_card.merge(
      "i18n" => { "fr" => { "text" => "Lesquels as-tu utilisés ?",
                            "modal_title" => "Avant de répondre" } }
    )
    s = published_with([ card ], locales: %w[en fr])
    get play_survey_path(s.publish_token), params: { lang: "fr" }

    assert_match "Avant de répondre", response.body
    assert_match "We mean services you used yourself.", response.body,
                 "the body has no French, so the player shows the wording it has"
  end

  test "only a card with a modal gets a re-open pill, and it starts hidden" do
    s = published_with([ plain_card, modal_card ])
    get play_survey_path(s.publish_token)

    assert_select "[data-role='card-modal-reopen'][hidden]", 1
    assert_select "[data-card-cid='c_plain'] [data-role='card-modal-reopen']", 0
  end

  test "a deck with no modals carries none of its markup" do
    s = published_with([ plain_card ])
    get play_survey_path(s.publish_token)

    assert_select "[data-role='card-modal']", 0
    assert_select "[data-role='card-modal-reopen']", 0
  end

  # ── Editor ────────────────────────────────────────────────────────────────

  test "every card gets an editable replica, shown only where there is a modal" do
    s = survey_with([ plain_card, modal_card ])
    sign_in!
    get survey_path(s)

    assert_response :success
    assert_select "[data-role='card-modal'].is-editing", 2,
                  "the nodes the serialiser reads must exist on every card"
    assert_select ".split-card.has-card-modal", 1,
                  "only the card that has one shows it"
    assert_select "[data-card-cid='c_modal'] [data-role='card-modal-title']", 1
    assert_select "[data-card-cid='c_modal'] [data-role='card-modal-body']", 1
  end

  test "the rail control reports which cards have one" do
    s = survey_with([ plain_card, modal_card ])
    sign_in!
    get survey_path(s)

    assert_select "[data-card-cid='c_plain'] [data-role='card-modal-btn'][aria-pressed='false']", 1
    assert_select "[data-card-cid='c_modal'] [data-role='card-modal-btn'][aria-pressed='true']", 1
  end

  test "the editor's replica is inert — it cannot be tabbed into and pressed" do
    s = survey_with([ modal_card ])
    sign_in!
    get survey_path(s)

    assert_select ".card-modal-layer.is-editing .card-modal-cta[tabindex='-1']", 1
  end

  test "the editor's per-language store carries the modal's words" do
    card = modal_card.merge("i18n" => { "fr" => { "modal_title" => "Avant de répondre" } })
    s = survey_with([ card ], locales: %w[en fr])
    sign_in!
    get survey_path(s)

    blob = JSON.parse(css_select("#survey-cards-i18n").first.text)
    assert_equal "Before you answer this one", blob.first["modal_title"]
    assert_equal "Avant de répondre", blob.first.dig("i18n", "fr", "modal_title")
  end

  test "the JS-facing strings the rail relabels itself with reach the browser" do
    s = survey_with([ modal_card ])
    sign_in!
    get survey_path(s)

    # A string the JS reads but the slice never carried renders as a raw dotted
    # key in the rail (BUG-004) — see layouts/_i18n_js.
    js = response.body[/window\.I18N = (\{.*?\});/m, 1]
    strings = JSON.parse(js)
    %w[modal_add modal_on modal_remove modal_remove_confirm].each do |key|
      assert strings.dig("editor", key).present?, "editor.#{key} must reach window.I18N"
    end
  end

  # ── Autosave ──────────────────────────────────────────────────────────────

  test "a modal saved through autosave survives, and blanking it removes it" do
    s = survey_with([ modal_card ])
    sign_in!

    patch survey_path(s), params: {
      cards: [ modal_card.merge("modal_title" => "  New heading  ",
                                "modal_body" => "New words.") ]
    }, as: :json
    assert_equal "New heading", s.reload.cards.first["modal_title"]

    patch survey_path(s), params: {
      cards: [ modal_card.except("modal_title", "modal_body") ]
    }, as: :json
    refute s.reload.cards.first.key?("modal_title"),
           "Remove blanks the nodes, so the next save simply carries neither key"
    refute s.cards.first.key?("modal_body")
  end
end
