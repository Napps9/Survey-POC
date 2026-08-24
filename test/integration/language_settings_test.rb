require "test_helper"

# The editor's Language block (surveys#update_languages + the
# auto_detect_language switch) and the player behaviour it controls.
class LanguageSettingsTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "multiple_choice", "text" => "Q", "options" => [ "A", "B" ],
      "i18n" => { "de" => { "text" => "F", "options" => [ "Ah", "Beh" ] } } }
  ].freeze

  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "lang-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "lang-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    org
  end

  def survey_for(org, locales: %w[en de], published: false)
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: locales, cards: CARDS.map(&:dup),
      publish_token: published ? SecureRandom.urlsafe_base64(18) : nil,
      published_at:  published ? Time.current : nil
    )
  end

  test "ticking a new language stores it and queues a translation pass for just that language" do
    org = sign_in_org("add")
    s = survey_for(org)

    assert_enqueued_with(job: TranslateLocalesJob, args: [ s.id, [ "fr" ] ]) do
      post survey_languages_path(s), params: { default_locale: "en", locales: [ "de", "fr" ] }
    end
    assert_redirected_to survey_path(s, panel: "publish")
    assert_equal %w[en de fr], s.reload.verto_locales
  end

  test "unticking a language deselects it but keeps its translations on the cards" do
    org = sign_in_org("remove")
    s = survey_for(org)

    assert_no_enqueued_jobs(only: TranslateLocalesJob) do
      post survey_languages_path(s), params: { default_locale: "en", locales: [] }
    end
    s.reload
    assert_equal %w[en], s.verto_locales
    assert_equal "F", s.cards.first.dig("i18n", "de", "text"), "the stored translation survives deselection"
  end

  test "changing the primary swaps the canonical language on a draft" do
    org = sign_in_org("primary")
    s = survey_for(org)

    post survey_languages_path(s), params: { default_locale: "de", locales: [ "en" ] }
    assert_redirected_to survey_path(s, panel: "publish")
    s.reload
    assert_equal "de", s.default_locale
    assert_equal "F", s.cards.first["text"]
    assert_equal "Q", s.cards.first.dig("i18n", "en", "text")
  end

  test "the primary is fixed once live — the guard surfaces as language_error" do
    org = sign_in_org("locked")
    s = survey_for(org, published: true)

    post survey_languages_path(s), params: { default_locale: "de", locales: [ "de" ] }
    assert_redirected_to survey_path(s, panel: "publish", language_error: "primary")
    assert_equal "en", s.reload.default_locale
  end

  test "auto_detect_language is a settings switch" do
    org = sign_in_org("detect")
    s = survey_for(org)
    assert s.auto_detect_language?, "detection is on by default"

    post survey_settings_path(s), params: { auto_detect_language: "0" }
    assert_not s.reload.auto_detect_language?

    post survey_settings_path(s), params: { auto_detect_language: "1" }
    assert s.reload.auto_detect_language?
  end

  test "the player follows the browser language only while detection is on" do
    org = sign_in_org("player")
    s = survey_for(org, published: true)

    # Detection on (default): a German browser gets the German cards.
    get play_survey_path(s.publish_token), headers: { "Accept-Language" => "de" }
    assert_response :success
    assert_match "F", response.body

    # Detection off: the same browser starts in the primary language…
    s.update!(auto_detect_language: false)
    get play_survey_path(s.publish_token), headers: { "Accept-Language" => "de" }
    assert_response :success
    assert_match "Q", response.body
    assert_no_match ">F<", response.body

    # …and the respondent's own explicit choice still wins.
    get play_survey_path(s.publish_token, lang: "de"), headers: { "Accept-Language" => "de" }
    assert_response :success
    assert_match "F", response.body
  end
end
