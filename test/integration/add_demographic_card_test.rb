require "test_helper"

# The add-question modal's Demographics tiles: the endpoint hands back a fully
# formed, locale-resolved registry card (generate_card's {ok, card, html}
# shape), refuses duplicates and unknown keys, respects the editing lock, and
# the editor page renders the tiles with server-side grey-out.
class AddDemographicCardTest < ActionDispatch::IntegrationTest
  def setup
    @org  = Organisation.create!(name: "ADC", slug: "adc-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "adc-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  def survey(locales: [ "en" ], default_locale: "en", cards: [])
    @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: default_locale, locales: locales, cards: cards
    )
  end

  def add!(s, key)
    post demographic_survey_card_path(s),
         params: { key: key }.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  test "adding heritage returns the registry card, stamped and rendered" do
    add!(survey, "heritage")

    assert_response :success
    json = JSON.parse(response.body)
    assert json["ok"]
    card = json["card"]
    assert card["cid"].present?
    assert card["demographic"]
    assert_equal "heritage", card["demographic_key"]
    assert_equal 9, card["options"].size
    assert_includes json["html"], 'data-card-demographic-key="heritage"',
                    "the editor row must carry the key or autosave strips it"
  end

  test "a multilingual Verto gets its translations prefilled from the locale files" do
    add!(survey(locales: %w[en fr]), "neurodiversity")

    json = JSON.parse(response.body)
    fr = json.dig("card", "i18n", "fr")
    assert fr.present?, "the next autosave must not persist the card monolingual"
    refute_equal json.dig("card", "text"), fr["text"]
    assert_equal 9, fr["options"].size
  end

  test "a French-default Verto gets the French card at the top level" do
    add!(survey(locales: [ "fr" ], default_locale: "fr"), "heritage")

    json = JSON.parse(response.body)
    assert_equal DemographicQuestions.optional_card("heritage", locale: "fr")["text"],
                 json.dig("card", "text")
  end

  test "unknown keys, duplicates and locked Vertos are refused" do
    add!(survey, "astrology")
    assert_response :unprocessable_entity

    s = survey(cards: [ DemographicQuestions.optional_card("heritage") ])
    add!(s, "heritage")
    assert_response :unprocessable_entity
    refute JSON.parse(response.body)["ok"]

    live = survey
    live.update!(publish_token: SecureRandom.hex(8))
    add!(live, "neurodiversity")
    assert_response :locked
  end

  test "another organisation's Verto is not reachable" do
    other_org = Organisation.create!(name: "X", slug: "x-#{SecureRandom.hex(2)}")
    foreign = other_org.surveys.create!(
      title: "S", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: []
    )

    add!(foreign, "heritage")
    assert_response :not_found
  end

  test "the editor renders the tiles and greys out an added one" do
    s = survey(cards: [ DemographicQuestions.optional_card("heritage") ])
    get survey_path(s)

    assert_response :success
    assert_select "button[data-demographic-key=heritage][disabled]", 1
    assert_select "button[data-demographic-key=neurodiversity]:not([disabled])", 1
  end
end
