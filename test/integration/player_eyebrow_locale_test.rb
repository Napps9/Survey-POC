require "test_helper"

class PlayerEyebrowLocaleTest < ActionDispatch::IntegrationTest
  # The card's "how to answer" caption (.q-eyebrow, e.g. "Choose one") is
  # derived from the card's type via config/card_types.yml, not authored
  # per-card, so it isn't in the card's own i18n hash — it must be looked up
  # in the RESPONDENT's display locale independently. Regression coverage for
  # the caption staying in English regardless of ?lang=.
  def published_survey
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    survey = org.surveys.create!(
      title: "Sports", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en", "es" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[a b c] }
      ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))
    survey
  end

  test "the answer-type caption follows the player's display locale, not the card's primary language" do
    survey = published_survey

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select ".q-eyebrow", text: I18n.t("card.eyebrow.multiple_choice", locale: "en")

    get play_survey_path(survey.publish_token, lang: "es")
    assert_response :success
    assert_select ".q-eyebrow", text: I18n.t("card.eyebrow.multiple_choice", locale: "es")

    # Guards against the caption silently falling back to English because the
    # target locale has no translation for this key.
    refute_equal I18n.t("card.eyebrow.multiple_choice", locale: "en"),
                 I18n.t("card.eyebrow.multiple_choice", locale: "es")
  end

  # A capped multi-select's caption is the ONLY place a respondent is told the
  # rule — the player refuses the extra tap in silence — so it has to reach them
  # in their own language like every other caption, not just in English.
  test "a capped multi-select says its cap, in the display locale" do
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    survey = org.surveys.create!(
      title: "Sports", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en", "es" ],
      cards: [ { "type" => "select_many", "text" => "Pick some",
                 "options" => %w[a b c d], "max_choices" => 2 } ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))

    get play_survey_path(survey.publish_token)
    assert_select ".q-eyebrow", text: I18n.t("card.eyebrow_max", n: 2, locale: "en")
    # The number the browser enforces comes off the same card as the caption.
    assert_select "ul.choice-list[data-picker-max-value='2']", 1

    get play_survey_path(survey.publish_token, lang: "es")
    assert_select ".q-eyebrow", text: I18n.t("card.eyebrow_max", n: 2, locale: "es")

    refute_equal I18n.t("card.eyebrow_max", n: 2, locale: "en"),
                 I18n.t("card.eyebrow_max", n: 2, locale: "es")
    refute_equal I18n.t("card.eyebrow.select_many", locale: "en"),
                 I18n.t("card.eyebrow_max", n: 2, locale: "en"),
                 "a cap that reads the same as no cap tells the respondent nothing"
  end
end
