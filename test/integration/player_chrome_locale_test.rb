require "test_helper"

# Card CONTENT has always followed the Verto's own language
# (Survey#display_locale_for); the surrounding CHROME — Back/Next/Submit, the
# consent gate, window.I18N, <html lang> — has always followed the visitor's
# own locale instead (ApplicationController#resolve_locale), so a Spanish
# Verto opened by an English-browser visitor showed Spanish questions against
# English buttons. chrome_follows_verto_language is the opt-in override.
class PlayerChromeLocaleTest < ActionDispatch::IntegrationTest
  def survey(chrome_follows: false, locales: [ "es", "en" ])
    org = Organisation.create!(name: "Acme", slug: "ccl-#{SecureRandom.hex(2)}")
    org.surveys.create!(
      title: "Encuesta", theme: "Salud", audience_age: "all", key_insight: "x",
      default_locale: "es", locales: locales,
      chrome_follows_verto_language: chrome_follows,
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "welcome_card", "title" => "hola" },
               { "type" => "multiple_choice", "text" => "¿Uno?", "options" => %w[a b] } ]
    )
  end

  def i18n_payload(body)
    script = body[/window\.I18N = (\{.*?\});/m, 1]
    assert script, "the layout no longer renders window.I18N"
    JSON.parse(script)
  end

  test "off (default): chrome follows the visitor, content follows the Verto" do
    s = survey(chrome_follows: false)

    get play_survey_path(s.publish_token, locale: "en")
    assert_response :success

    # Chrome — the visitor's English, unaffected by the Verto's own language.
    # player.next is static server-rendered text (never in window.I18N — see
    # the next assertion for a key JS actually reads at runtime), so it's the
    # right thing to check directly against the rendered HTML.
    assert_match I18n.t("player.next", locale: "en"), response.body
    assert_select "html[lang=?]", "en"
    assert_equal I18n.t("player.consent_agree", locale: "en"), i18n_payload(response.body).dig("player", "consent_agree")

    # Content — the Verto's Spanish, unaffected by the visitor's own locale.
    assert_match "¿Uno?", response.body
  end

  test "on: chrome follows the Verto's language instead" do
    # Only "es" here (not "en" too, unlike the shared default) — otherwise the
    # visitor's own "en" would legitimately win content resolution too
    # (Survey#display_locale_for prefers Current.locale whenever it's one of
    # the Verto's own locales), and the test would no longer distinguish
    # "chrome follows content" from "content happens to match the visitor".
    s = survey(chrome_follows: true, locales: [ "es" ])

    get play_survey_path(s.publish_token, locale: "en")
    assert_response :success

    assert_match I18n.t("player.next", locale: "es"), response.body
    refute_match I18n.t("player.next", locale: "en"), response.body,
      "the English chrome string must not also appear once the Verto's language wins"
    assert_select "html[lang=?]", "es"
    assert_equal I18n.t("player.consent_agree", locale: "es"), i18n_payload(response.body).dig("player", "consent_agree")

    # Content is unchanged — it already followed the Verto's language.
    assert_match "¿Uno?", response.body
  end

  test "on: chrome follows whichever content language actually resolved, including an explicit ?lang=" do
    s = survey(chrome_follows: true)

    # ?lang=en asks for the ENGLISH content locale explicitly (the visitor's
    # own platform locale is separately forced to es here, so this proves the
    # chrome follows @display_locale specifically — not just the visitor's
    # locale by coincidence).
    get play_survey_path(s.publish_token, locale: "es", lang: "en")
    assert_response :success

    assert_match I18n.t("player.next", locale: "en"), response.body
    assert_select "html[lang=?]", "en"
  end

  test "the toggle round-trips through settings on a live Verto" do
    user = User.create!(name: "U", email_address: "ccl-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "ccl2-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: user, role: "admin")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                            default_locale: "en", locales: [ "en" ],
                            publish_token: SecureRandom.hex(8), published_at: Time.current,
                            cards: [ { "type" => "welcome_card", "title" => "hi" } ])
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    refute s.chrome_follows_verto_language?
    post survey_settings_path(s), params: { chrome_follows_verto_language: "1" }
    assert s.reload.chrome_follows_verto_language?

    post survey_settings_path(s), params: { chrome_follows_verto_language: "0" }
    refute s.reload.chrome_follows_verto_language?
  end

  test "the owner's dashboard preview honours the toggle too" do
    user = User.create!(name: "U", email_address: "ccl3-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "ccl3-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: user, role: "admin")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "k",
                            default_locale: "es", locales: [ "es" ],
                            chrome_follows_verto_language: true,
                            cards: [ { "type" => "welcome_card", "title" => "hola" } ])
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get preview_survey_path(s, locale: "en")
    assert_response :success
    assert_match I18n.t("player.next", locale: "es"), response.body
  end
end
