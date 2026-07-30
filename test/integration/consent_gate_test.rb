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

  test "update_settings stores and clears the consent text on a draft" do
    org = sign_in_org("consent-set")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS)

    post survey_settings_path(s), params: { consent_text: "  You agree to take part.  " }
    assert_equal "You agree to take part.", s.reload.consent_text
    assert s.consent_required?

    post survey_settings_path(s), params: { consent_text: "   " }
    assert_nil s.reload.consent_text
    assert_not s.consent_required?
  end

  # ── Consent can't be bolted on after the fact ─────────────────────────────
  # update_settings used to be the only content endpoint with no lock, so a
  # consent gate could be added to a Verto people had already answered — leaving
  # their responses with a nil consent_text_snapshot while the Verto claimed
  # everyone had agreed to something.

  test "a live Verto refuses consent changes" do
    org = sign_in_org("consent-live")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: { consent_text: "Agree, retroactively." }
    assert_redirected_to survey_path(s, panel: "publish")
    assert_nil s.reload.consent_text

    post survey_settings_path(s), params: { consent_image: "https://images.pexels.com/photos/12/race.jpg" }
    assert_nil s.reload.consent_image
  end

  test "a closed Verto with responses still refuses consent changes" do
    org = sign_in_org("consent-closed")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    s.responses.create!(session_token: SecureRandom.uuid, answers: {}, answered: true, status: "completed")
    s.update!(unpublished_at: Time.current)

    assert_not s.published?, "it's been taken down…"
    assert s.editing_locked?, "…but the responses keep it locked"

    post survey_settings_path(s), params: { consent_text: "Too late." }
    assert_nil s.reload.consent_text
  end

  test "a Verto unpublished before anyone answered accepts consent again" do
    org = sign_in_org("consent-revert")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    s.update!(unpublished_at: Time.current)

    post survey_settings_path(s), params: { consent_text: "Now it's a draft again." }
    assert_equal "Now it's a draft again.", s.reload.consent_text
  end

  test "the scoring switches are locked too, and the JSON path reports it" do
    org = sign_in_org("consent-score")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: { quiz: "1" }
    assert_not s.reload.quiz?

    post survey_settings_path(s), params: { tokenisation_enabled: "1" }
    assert_not s.reload.tokenisation_enabled?

    # The in-feed gate cards save by fetch, so that path needs a real status.
    post survey_settings_path(s), params: { consent_text: "nope" }, as: :json
    assert_response :locked
    assert_not JSON.parse(response.body)["ok"]
  end

  # Presentation and distribution stay editable for the life of a Verto —
  # a blanket guard here would have been wrong.
  test "a live Verto still accepts presentation and distribution settings" do
    org = sign_in_org("consent-open")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: {
      show_results_comparison: "1", compare_note: "still fine",
      thankyou_title: "Thanks!", forward_url: "example.org", forward_label: "Visit"
    }
    s.reload
    assert s.show_results_comparison
    assert_equal "still fine", s.compare_note
    assert_equal "Thanks!", s.thankyou_title
    assert_equal "https://example.org", s.forward_url
    assert_equal "Visit", s.forward_label
  end

  test "the editor stops offering a consent gate once the Verto is in use" do
    org = sign_in_org("consent-ui")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS)

    get survey_path(s)
    assert_select "[data-gate-cards-target='consentCta']:not([hidden])"

    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    get survey_path(s)
    assert_select "[data-gate-cards-target='consentCta'][hidden]"
    assert_select "input[name='quiz'][disabled]"
    assert_select "input[name='tokenisation_enabled'][disabled]"
  end

  # An existing gate stays visible when locked — the creator still needs to read
  # what respondents actually agreed to — but not editable.
  test "an existing consent gate is shown read-only when locked" do
    org = sign_in_org("consent-ro")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            consent_text: "You agreed to this.",
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get survey_path(s)
    assert_select "[data-gate-cards-target='consentCard']:not([hidden])"
    assert_select "[data-gate-cards-target='consentBody']", text: "You agreed to this."
    assert_select "[data-gate-cards-target='consentBody'][contenteditable='true']", false
    assert_select "[data-action*='removeConsent']", false
    assert_select "[data-action*='media-picker#openConsent']", false
  end

  test "update_settings stores the consent image and rejects unsafe URLs with their credit" do
    org = sign_in_org("consent-img")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS)

    post survey_settings_path(s), params: {
      consent_image: "https://images.pexels.com/photos/12/race.jpg?auto=compress",
      consent_image_credit: "  Jane Doe  ",
      consent_image_credit_url: "https://www.pexels.com/@janedoe"
    }
    s.reload
    assert_equal "https://images.pexels.com/photos/12/race.jpg?auto=compress", s.consent_image
    assert_equal "Jane Doe", s.consent_image_credit
    assert_equal "https://www.pexels.com/@janedoe", s.consent_image_credit_url

    # A URL outside the allowed forms is dropped, and the now-orphaned credit
    # goes with it (same convention as the card image sanitizer).
    post survey_settings_path(s), params: {
      consent_image: "javascript:alert(1)",
      consent_image_credit: "Mallory",
      consent_image_credit_url: "https://evil.example/x"
    }
    s.reload
    assert_nil s.consent_image
    assert_nil s.consent_image_credit
    assert_nil s.consent_image_credit_url
  end

  test "editor consent card offers Add design, then Change design once an image is set" do
    org = sign_in_org("consent-fab")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            consent_text: "Agree to continue.")

    get survey_path(s)
    assert_response :success
    assert_select "[data-gate-cards-target='consentLeft'] button.split-left-design-prompt[data-action='click->media-picker#openConsent']"

    s.update!(consent_image: "https://images.pexels.com/photos/12/race.jpg")
    get survey_path(s)
    assert_select "[data-gate-cards-target='consentLeft'] .split-left-img[data-consent-media]"
    assert_select "[data-gate-cards-target='consentLeft'] button.add-media-fab[data-action='click->media-picker#openConsent']"
  end

  test "player consent card shows the creator's design image with its credit" do
    s = published_survey(consent: "Agree to continue.")
    s.update!(consent_image: "https://images.pexels.com/photos/12/race.jpg",
              consent_image_credit: "Jane Doe",
              consent_image_credit_url: "https://www.pexels.com/@janedoe")

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select ".preview-card[data-card-type='consent_card'] .split-left .split-left-img"
    assert_select ".preview-card[data-card-type='consent_card'] .split-left-credit a[href=?]",
                  "https://www.pexels.com/@janedoe", text: /Jane Doe/
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
