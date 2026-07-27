require "test_helper"

# Adding a saved Common Question from inside the editor (previously only
# possible in the creation wizard), and the provenance ids that let results
# aggregate the same question across Vertos surviving a round-trip.
class EditorLibraryPickerTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "O", slug: "lib-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "lib-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")

    @set = @org.common_question_sets.create!(name: "Core outcomes")
    @question = @set.common_questions.create!(
      text: "How confident do you feel?", card_type: "range",
      options: [ "Not at all", "A little", "Somewhat", "Quite", "Very" ]
    )

    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "cid" => "c_w", "title" => "hi" } ]
    )
    sign_in
  end

  def sign_in(user = @user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "the editor modal offers the library and lists the org's saved questions" do
    get survey_path(@survey)
    assert_response :success
    assert_match "From your library", response.body
    assert_select "[data-add-question-target='stepLibrary']"
    assert_select "button.aq-library-item[data-card]", minimum: 1
    assert_match "How confident do you feel?", response.body
    assert_match "Core outcomes", response.body
  end

  test "a picked question's payload carries the provenance ids" do
    get survey_path(@survey)
    payload = css_select("button.aq-library-item").first["data-card"]
    card    = JSON.parse(payload)

    assert_equal "range", card["type"]
    assert_equal "How confident do you feel?", card["text"]
    assert_equal @question.id, card["common_question_id"]
    assert_equal @set.id, card["common_question_set_id"]
  end

  test "render_card returns markup carrying the provenance as data attributes" do
    post render_survey_card_path(@survey), params: @question.to_card.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    html = JSON.parse(response.body)["html"]
    assert_includes html, "data-card-common-question-id=\"#{@question.id}\""
    assert_includes html, "data-card-common-question-set-id=\"#{@set.id}\""
  end

  test "the provenance survives an autosave round-trip" do
    # The regression this guards: the editor rebuilds every card from the DOM on
    # autosave, so an id that isn't carried through would be silently dropped and
    # the cross-Verto rollup would quietly stop counting this question.
    patch survey_path(@survey),
          params: { cards: [ @question.to_card.merge("cid" => "c_q") ] }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    card = @survey.reload.cards.first
    assert_equal @question.id, card["common_question_id"]
    assert_equal @set.id, card["common_question_set_id"]
  end

  test "junk provenance is dropped rather than stored" do
    patch survey_path(@survey),
          params: { cards: [ { "type" => "yes_no", "cid" => "c_j", "text" => "Q",
                               "common_question_id" => "not-a-number",
                               "common_question_set_id" => 0 } ] }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    card = @survey.reload.cards.first
    assert_not card.key?("common_question_id")
    assert_not card.key?("common_question_set_id")
  end

  test "a card still aggregates by provenance after being added and saved" do
    patch survey_path(@survey),
          params: { cards: [ @question.to_card.merge("cid" => "c_q") ] }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    @survey.reload
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "0" => { "value" => "Very" } })

    result = CommonQuestionAggregator.new(@set, [ @survey ]).aggregate
    assert result.present?, "the aggregator should see the question through its provenance id"
  end

  test "another organisation's sets are never offered" do
    other_org = Organisation.create!(name: "Other", slug: "lib-other-#{SecureRandom.hex(3)}")
    other_set = other_org.common_question_sets.create!(name: "Secret set")
    other_set.common_questions.create!(text: "Their private question", card_type: "yes_no",
                                       options: [ "Yes", "No" ])

    get survey_path(@survey)
    assert_response :success
    assert_no_match "Secret set", response.body
    assert_no_match "Their private question", response.body
  end

  test "the library tile is hidden when the org has no saved questions" do
    bare_org  = Organisation.create!(name: "Bare", slug: "lib-bare-#{SecureRandom.hex(3)}")
    bare_user = User.create!(name: "B", email_address: "bare-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    bare_org.memberships.create!(user: bare_user, role: "admin")
    bare_survey = bare_org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: []
    )

    delete session_path
    sign_in(bare_user)

    get survey_path(bare_survey)
    assert_response :success
    assert_no_match "From your library", response.body
  end
end
