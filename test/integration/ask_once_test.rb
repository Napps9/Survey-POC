require "test_helper"

# Server-side half of the per-question "ask once" toggle: the flag survives the
# stack, the player page carries it, and the durable identity is recorded for
# decks that use it (the promise is made to an identity).
class AskOnceTest < ActionDispatch::IntegrationTest
  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "ao-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "ao-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    org
  end

  CARDS = [
    { "type" => "multiple_choice", "text" => "Industry?", "options" => [ "Arts", "Tech" ], "ask_once" => true },
    { "type" => "yes_no", "text" => "Coming back?", "options" => [ "Yes", "No" ] }
  ].freeze

  def live_survey(org)
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  test "ask_once survives the editor autosave round-trip" do
    org = sign_in_org("save")
    s = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup)
    )

    patch survey_path(s), params: { cards: s.cards }.to_json,
          headers: { "Content-Type" => "application/json" }
    assert_response :success
    assert s.reload.cards.first["ask_once"], "the serializer field must round-trip"
    assert s.ask_once_cards?
  end

  test "the player page and the editor row both carry the flag" do
    org = sign_in_org("attrs")
    s = live_survey(org)

    get play_survey_path(s.publish_token)
    assert_select "div.preview-card[data-card-ask-once=true]", 1
    assert_select "div.preview-card[data-card-ask-once=false]", 1

    get survey_path(s)
    assert_select "[data-card-ask-once=true]", minimum: 1
    assert_select "input[data-survey-editor-target=panelAskOnce]", 1
  end

  test "an ask-once deck records the durable identity even with leaderboard and contacts off" do
    org = sign_in_org("ident")
    s = live_survey(org)
    assert s.player_identity_active?

    key = SecureRandom.uuid
    post progress_survey_path(s.publish_token),
         params: { session_token: "ao-1", answers: { "0" => { "type" => "multiple_choice", "value" => "Arts" } },
                   player_key: key },
         as: :json
    assert_response :success
    assert_equal s.player_key_digest(key), s.responses.find_by(session_token: "ao-1").player_key_digest
  end

  test "a plain deck still records no identity" do
    org = sign_in_org("plain")
    s = live_survey(org)
    s.update!(cards: [ CARDS.last.dup ])
    assert_not s.player_identity_active?

    post progress_survey_path(s.publish_token),
         params: { session_token: "ao-2", answers: { "0" => { "type" => "yes_no", "value" => "Yes" } },
                   player_key: SecureRandom.uuid },
         as: :json
    assert_response :success
    assert_nil s.responses.find_by(session_token: "ao-2").player_key_digest
  end
end
