require "test_helper"

class ConsentGateTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def published_survey(consent: nil)
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS, consent_text: consent,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "update_settings stores and clears the consent text" do
    org = sign_in_org("consent-set")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: { consent_text: "  You agree to take part.  " }
    assert_equal "You agree to take part.", s.reload.consent_text
    assert s.consent_required?

    post survey_settings_path(s), params: { consent_text: "   " }
    assert_nil s.reload.consent_text
    assert_not s.consent_required?
  end

  test "consent shows as the first card when consent text is set" do
    s = published_survey(consent: "You agree your anonymous answers may be used for research.")

    get play_survey_path(s.publish_token)
    assert_response :success
    # It's a real card in the deck, with agree/decline actions.
    assert_select ".preview-card[data-card-type='consent_card']"
    assert_select ".play-consent-body", /anonymous answers/
    assert_select "button[data-action='click->player#agreeConsent']"
    assert_select "button[data-action='click->player#declineConsent']"
    # Critically it carries NO data-card-index, so it never shifts answer keys
    # (which align to the @survey.cards index).
    assert_select ".preview-card[data-card-type='consent_card'][data-card-index]", false
  end

  test "no consent card when consent text is blank" do
    s = published_survey(consent: nil)

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select ".preview-card[data-card-type='consent_card']", false
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
    JSON.parse(response.body)
  end

  test "consent endpoint records agreement with a timestamp and a snapshot of the wording" do
    s = published_survey(consent: "You agree your anonymous answers may be used for research.")

    body = json_post consent_survey_path(s.publish_token), session_token: "consent-1", agreed: true
    assert_response :success
    assert body["ok"]

    resp = Response.find_by!(session_token: "consent-1")
    assert_not_nil resp.consent_agreed_at
    assert_nil resp.consent_declined_at
    assert_equal s.consent_text, resp.consent_text_snapshot
    # A consent-only ping (no answers yet) must not read as a completed
    # response — the schema column defaults to "completed", which would
    # otherwise corrupt completion-rate stats for someone who agreed then left.
    assert_equal "started", resp.status
  end

  test "consent endpoint records a decline separately from an agreement" do
    s = published_survey(consent: "Agree to continue.")

    body = json_post consent_survey_path(s.publish_token), session_token: "consent-2", agreed: false
    assert_response :success
    assert body["ok"]

    resp = Response.find_by!(session_token: "consent-2")
    assert_nil resp.consent_agreed_at
    assert_not_nil resp.consent_declined_at
    assert_equal s.consent_text, resp.consent_text_snapshot
  end

  test "consent endpoint never overwrites an already-recorded event" do
    s = published_survey(consent: "Original wording.")

    json_post consent_survey_path(s.publish_token), session_token: "consent-3", agreed: true
    first_timestamp = Response.find_by!(session_token: "consent-3").consent_agreed_at

    s.update!(consent_text: "Edited wording, after the fact.")
    travel 1.hour do
      json_post consent_survey_path(s.publish_token), session_token: "consent-3", agreed: true
    end

    resp = Response.find_by!(session_token: "consent-3")
    assert_equal first_timestamp.to_i, resp.consent_agreed_at.to_i
    # The snapshot from the moment of the FIRST agreement survives, not the
    # since-edited text — that's the whole point of snapshotting.
    assert_equal "Original wording.", resp.consent_text_snapshot
  end
end
