require "test_helper"

# Card CONTENT follows the Verto's own language (Survey#display_locale_for).
# The surrounding CHROME — Back/Next/Submit, the consent gate, window.I18N,
# <html lang> — used to follow the visitor's own locale instead
# (ApplicationController#resolve_locale), so a Spanish Verto opened by an
# English-browser visitor showed Spanish questions against English buttons.
#
# That reached the field as something worse than untidy. The consent gate is
# chrome, and its default copy names what the Verto collects — so a browser
# set to German got a German consent box, German buttons and an
# <html lang="de"> over questions written in English, on a Verto not offered
# in German at all: "the Consent Box for Age and Residence still in German".
#
# chrome_follows_verto_language defaults to TRUE now, and existing rows were
# backfilled (a default only reaches new INSERTs). It remains as the opt-out
# for a Verto that would rather meet each respondent in their own language.
class PlayerChromeLocaleTest < ActionDispatch::IntegrationTest
  def survey(chrome_follows: true, locales: [ "es", "en" ])
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

  test "off: chrome follows the visitor, content follows the Verto" do
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

  test "on (the default): chrome follows the Verto's language instead" do
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

  # ── The field report ──────────────────────────────────────────────────────

  # An English-only Verto, a browser asking for German, and NOTHING configured
  # — exactly what a creator gets by publishing and sharing a link. Before the
  # default flipped this served player.consent_default_text in German, which
  # reads "…nach deinem Geburtsdatum, deinem Wohnort und deinem Geschlecht":
  # the age and residence in the report, in a language this Verto never
  # offered, above questions still in English.
  test "a browser in a language the Verto does not speak gets the Verto's language, not its own" do
    org = Organisation.create!(name: "Acme", slug: "ccl4-#{SecureRandom.hex(2)}")
    s = org.surveys.create!(
      title: "EFA26", theme: "Sport", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "welcome_card", "title" => "Welcome" },
               # "demographic" is what makes the consent gate appear at all
               # (Survey#collects_personal_data?), and it is the birth-date
               # card the German copy is about.
               { "type" => "open_ended", "input" => "month", "demographic" => true,
                 "text" => "When were you born?" } ])

    assert s.show_consent_gate?, "precondition: this Verto must be showing a consent gate"

    get play_survey_path(s.publish_token),
        headers: { "HTTP_ACCEPT_LANGUAGE" => "de-DE,de;q=0.9" }
    assert_response :success

    assert_includes response.body,
                    ERB::Util.html_escape(I18n.t("player.consent_default_text", locale: "en")),
                    "the consent box is not in the Verto's own language"
    refute_includes response.body,
                    ERB::Util.html_escape(I18n.t("player.consent_default_text", locale: "de")),
                    "the consent box is in German on a Verto that only speaks English — the " \
                    "reported bug, in the exact string that was reported (Geburtsdatum, Wohnort)"
    assert_select "html[lang=?]", "en"
    assert_match "When were you born?", response.body,
                 "the card content was English all along; that half was never the bug"
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

    assert s.chrome_follows_verto_language?, "a new Verto should start in its own language"

    post survey_settings_path(s), params: { chrome_follows_verto_language: "0" }
    refute s.reload.chrome_follows_verto_language?

    post survey_settings_path(s), params: { chrome_follows_verto_language: "1" }
    assert s.reload.chrome_follows_verto_language?
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
