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
end
