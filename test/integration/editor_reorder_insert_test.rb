require "test_helper"

# Covers the editor changes: a per-card "Add question" CTA under every card,
# per-question reorder controls, and the render_card endpoint that the
# add-question flow depends on (previously 500'd because @survey was unset).
class EditorReorderInsertTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "edit-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "edit-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Edit", theme: "Sports", audience_age: "under 25's", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[a b c] },
        { "type" => "yes_no", "text" => "Yes or no?" }
      ]
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "each card is wrapped in a slot with its own Add question CTA" do
    get survey_path(@survey)
    assert_response :success
    cards = Array(@survey.cards).size
    assert_equal cards, response.body.scan('class="card-slot"').size, "one slot per card"
    assert_equal cards, response.body.scan('class="aq-insert-row"').size, "one insert CTA per card"
  end

  test "question cards get reorder controls; the welcome card does not" do
    get survey_path(@survey)
    assert_response :success
    questions = Array(@survey.cards).count { |c| c["type"] != "welcome_card" }
    assert_equal questions, response.body.scan("survey-editor#moveCardUp").size
    assert_equal questions, response.body.scan("survey-editor#moveCardDown").size
    # The welcome card slot has no reorder block.
    assert_select ".survey-card-wrap[data-card-type='welcome_card'] .card-reorder", false
    # Card numbers carry the JS hook used to re-stamp them after a move.
    assert_select "[data-role='card-number']", minimum: 1
  end

  test "render_card renders a question with reorder controls (regression: @survey was nil)" do
    post render_survey_card_path(@survey),
         params: { type: "multiple_choice", text: "New Q?", options: %w[a b] }.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["ok"], "render_card should succeed, got: #{json['error']}"
    assert_includes json["html"], "survey-card-wrap"
    assert_includes json["html"], "survey-editor#moveCardUp"
  end

  test "consent + thank-you are edited on in-feed gate cards, not panel textareas" do
    get survey_path(@survey)
    assert_response :success
    # The publish panel's consent/thank-you text fields moved into the feed as
    # editable gate cards (a CTA until one exists, then the card itself).
    assert_select "[data-gate-cards-target='consentCta']"
    assert_select "[data-gate-cards-target='consentBody'][contenteditable='true']"
    assert_select "[data-gate-cards-target='tyCta']"
    assert_select "[data-gate-cards-target='tyTitle'][contenteditable='true']"
    assert_select "[data-gate-cards-target='tyBody'][contenteditable='true']"
    assert_select "textarea[name='consent_text']", false
    assert_select "input[name='thankyou_title']", false
    # The publish panel is down to Preview / Status / Response comparison /
    # Share with Partners — the finish-link field left with the rest.
    assert_select "input[name='forward_url']", false
  end

  test "quiz answer textareas auto-grow (explanation + accepted answers)" do
    quiz = @org.surveys.create!(
      title: "Q", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], quiz: true,
      cards: [
        { "type" => "open_ended", "text" => "Why?" },
        { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] }
      ]
    )
    get survey_path(quiz)
    assert_response :success
    assert_select "textarea[data-quiz-explanation][data-controller='autogrow']", minimum: 1
    assert_select "textarea[data-quiz-accepted][data-controller='autogrow']", minimum: 1
  end

  test "a live Verto shows no insert or reorder chrome" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    get survey_path(@survey)
    assert_response :success
    refute_match "aq-insert-row", response.body
    refute_match "survey-editor#moveCardUp", response.body
  end
end
