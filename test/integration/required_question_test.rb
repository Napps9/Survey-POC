require "test_helper"

class RequiredQuestionTest < ActionDispatch::IntegrationTest
  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  test "editor shows the Required toggle and autosave persists the flag" do
    org = sign_in_org("req-edit")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ],
                            cards: [ { "type" => "welcome_card", "title" => "hi" },
                                     { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ])

    get survey_path(s)
    assert_response :success
    # The Required switch lives in the Answer Type tab's Card settings block
    # (one instance, acts on the selected card), with a passive chip on the
    # card chrome that JS unhides while the flag is on.
    assert_select "[data-survey-editor-target='cardFlags'] input[data-action='change->survey-editor#togglePanelRequired']"
    assert_select "[data-survey-editor-target='cardFlags'] input[data-action='change->survey-editor#togglePanelOther']"
    assert_select ".required-chip[data-role='required-chip']"

    # The autosave PATCH stores cards as sent — the required flag round-trips.
    patch survey_path(s),
          params: { cards: [ { "type" => "welcome_card", "title" => "hi" },
                             { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ], "required" => true } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
    assert_response :success
    assert_equal true, s.reload.cards.last["required"]
  end

  test "player flags required question cards and renders the nudge" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ],
                            cards: [ { "type" => "welcome_card", "title" => "hi" },
                                     { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ], "required" => true } ],
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get play_survey_path(s.publish_token)
    assert_response :success
    # The question card is flagged required; the welcome card is not.
    assert_select ".preview-card[data-card-type='yes_no'][data-card-required='true']"
    assert_select ".preview-card[data-card-type='welcome_card'][data-card-required='false']"
    # The nudge element is present (JS unhides it when the player blocks).
    assert_select "[data-player-target='requiredHint']"
  end
end
