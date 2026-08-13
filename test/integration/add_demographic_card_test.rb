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

  FIVE = [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ].freeze

  def survey(locales: [ "en" ], default_locale: "en", cards: [], audience_country: nil)
    @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: default_locale, locales: locales, cards: cards,
      audience_country: audience_country
    )
  end

  # The five country heritages arrive from Claude; stub the generator so the
  # endpoint's own behaviour is what's under test.
  def with_generator(result)
    fake = Object.new
    fake.define_singleton_method(:call) { |**| result }
    HeritageOptionsGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    HeritageOptionsGenerator.singleton_class.remove_method(:new)
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

  # ── Tailored to the Verto's audience country ──────────────────────────────

  test "with an audience country set, heritage arrives tailored to it" do
    with_generator(FIVE) { add!(survey(audience_country: "GB"), "heritage") }

    assert_response :success
    card = JSON.parse(response.body)["card"]
    assert_equal FIVE + DemographicQuestions.heritage_tail_options, card["options"]
    assert_equal 7, card["options"].size, "five categories plus the two escape hatches"
    assert card["allow_other"], "five will miss people — the free-text box is where they go"
    assert_equal "GB", card["heritage_country"]
    assert_equal "heritage", card["demographic_key"], "it is still the same question"
  end

  test "the tailored card's provenance and Other box reach the editor row" do
    with_generator(FIVE) { add!(survey(audience_country: "GB"), "heritage") }

    html = JSON.parse(response.body)["html"]
    assert_includes html, 'data-card-heritage-country="GB"',
                    "the row must carry it or the first autosave strips it"
    assert_includes html, 'data-card-allow-other="true"'
  end

  test "an unreachable generator still returns a working question" do
    with_generator(nil) { add!(survey(audience_country: "GB"), "heritage") }

    assert_response :success, "an API blip must not put an error where a card should be"
    card = JSON.parse(response.body)["card"]
    assert_equal 9, card["options"].size, "it falls back to the global taxonomy"
    assert_nil card["heritage_country"], "and doesn't claim a tailoring it didn't get"
    refute card["allow_other"]
  end

  test "a country the platform doesn't know is treated as no country" do
    s = survey
    s.update_column(:audience_country, "ZZ") # bypasses the model, as a stale row would
    with_generator(FIVE) { add!(s, "heritage") }

    assert_equal 9, JSON.parse(response.body)["card"]["options"].size
  end

  test "neurodiversity is untouched by the audience country" do
    called = false
    fake = Object.new
    fake.define_singleton_method(:call) { |**| called = true; FIVE }
    HeritageOptionsGenerator.define_singleton_method(:new) { |*| fake }
    begin
      add!(survey(audience_country: "GB"), "neurodiversity")
    ensure
      HeritageOptionsGenerator.singleton_class.remove_method(:new)
    end

    assert_equal 9, JSON.parse(response.body)["card"]["options"].size
    refute called, "only heritage varies by country"
  end

  test "the editor renders the tiles and greys out an added one" do
    s = survey(cards: [ DemographicQuestions.optional_card("heritage") ])
    get survey_path(s)

    assert_response :success
    assert_select "button[data-demographic-key=heritage][disabled]", 1
    assert_select "button[data-demographic-key=neurodiversity]:not([disabled])", 1
  end
end
