require "test_helper"

# The Verto-level audience country: the select in the Publish & share panel,
# the endpoint behind it, and the one thing it changes — whether the opt-in
# Heritage question asks in the global nine categories or the five that
# country's own people identify with.
class AudienceCountryTest < ActionDispatch::IntegrationTest
  FIVE = [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ].freeze

  def setup
    @org  = Organisation.create!(name: "AC", slug: "ac-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "ac-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
  end

  def survey(cards: [], **attrs)
    @org.surveys.create!(title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards, **attrs)
  end

  def with_generator(result)
    fake = Object.new
    fake.define_singleton_method(:call) { |**| result }
    HeritageOptionsGenerator.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    HeritageOptionsGenerator.singleton_class.remove_method(:new)
  end

  def set_country!(s, code)
    post audience_country_survey_path(s), params: { audience_country: code }
  end

  def heritage_card(s)
    Array(s.reload.cards).find { |c| c["demographic_key"] == "heritage" }
  end

  # ── The setting itself ────────────────────────────────────────────────────

  test "the editor offers every country, defaulting to none" do
    get survey_path(survey)

    assert_response :success
    assert_select "select[name=audience_country]" do
      assert_select "option[value='']", 1
      assert_select "option[value=GB]", text: "United Kingdom"
      assert_select "option[value=KE]", text: "Kenya"
    end
  end

  test "a valid code saves; junk is stored as nothing rather than rejected" do
    s = survey
    set_country!(s, "gb")
    assert_equal "GB", s.reload.audience_country, "codes are normalised, not echoed"

    set_country!(s, "ZZ")
    assert_nil s.reload.audience_country

    set_country!(s, "GB")
    set_country!(s, "")
    assert_nil s.reload.audience_country, "clearing back to the global list is a real choice"
  end

  test "the selected country is preselected when the panel reopens" do
    s = survey(audience_country: "KE")
    get survey_path(s)
    assert_select "select[name=audience_country] option[value=KE][selected]"
  end

  test "a live or answered Verto refuses the change" do
    s = survey(audience_country: "GB")
    s.update!(publish_token: SecureRandom.hex(8))

    set_country!(s, "KE")
    assert_redirected_to survey_path(s, panel: "publish")
    assert_equal "GB", s.reload.audience_country,
                 "its questions are frozen, so claiming a new audience would be a lie"
  end

  test "another organisation's Verto is not reachable" do
    other = Organisation.create!(name: "X", slug: "x-#{SecureRandom.hex(2)}")
    foreign = other.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "x",
                                    default_locale: "en", locales: [ "en" ], cards: [])
    set_country!(foreign, "GB")
    assert_response :not_found
  end

  # ── What it does to an existing Heritage card ─────────────────────────────

  test "setting a country retailors a Heritage card already in the deck" do
    s = survey(cards: [ { "type" => "yes_no", "text" => "Q", "cid" => "c_keep" },
                        DemographicQuestions.optional_card("heritage").merge("cid" => "c_her") ])

    with_generator(FIVE) { set_country!(s, "GB") }

    card = heritage_card(s)
    assert_equal FIVE + [ DemographicQuestions.heritage_decline_option ], card["options"]
    assert_equal 6, card["options"].size
    refute_includes card["options"], DemographicQuestions.another_heritage_label,
                    "'another' is something you type, not a dead-end radio"
    assert card["allow_other"], "a five-item list will miss people; the Other box is where they go"
    assert_equal "GB", card["heritage_country"]
    assert_equal "c_her", card["cid"], "the cid is what logic and answers point at — it must survive"
    assert_equal 2, s.reload.cards.size, "retailoring rewrites in place, it never appends"
  end

  test "clearing the country puts the global taxonomy back" do
    s = survey(audience_country: "GB",
               cards: [ DemographicQuestions.country_heritage_card(country: "GB", five: FIVE) ])

    set_country!(s, "")

    card = heritage_card(s)
    assert_equal 9, card["options"].size
    assert_nil card["heritage_country"]
    refute card["allow_other"], "the global list carries its own catch-all, so the box goes away with it"
  end

  test "a deck with no Heritage card costs nothing to retarget" do
    s = survey(cards: [ { "type" => "yes_no", "text" => "Q" } ])

    called = false
    fake = Object.new
    fake.define_singleton_method(:call) { |**| called = true; FIVE }
    HeritageOptionsGenerator.define_singleton_method(:new) { |*| fake }
    begin
      set_country!(s, "GB")
    ensure
      HeritageOptionsGenerator.singleton_class.remove_method(:new)
    end

    assert_equal "GB", s.reload.audience_country
    refute called, "most Vertos never add the card — changing the country must not spend for them"
  end

  test "an unreachable generator leaves a working Heritage card, not an error" do
    s = survey(cards: [ DemographicQuestions.optional_card("heritage").merge("cid" => "c_her") ])

    with_generator(nil) { set_country!(s, "GB") }

    assert_redirected_to survey_path(s, panel: "publish")
    card = heritage_card(s)
    assert_equal 9, card["options"].size, "it falls back to the global taxonomy"
    assert_nil card["heritage_country"], "and says so, rather than claiming a tailoring it didn't get"
  end

  test "retailoring drops translations that describe options no longer offered" do
    stale = DemographicQuestions.optional_card("heritage").merge(
      "cid"  => "c_her",
      "i18n" => { "fr" => { "text" => "vieux", "options" => Array.new(9, "vieux") } }
    )
    s = survey(cards: [ stale ], locales: %w[en fr])

    with_generator(FIVE) { set_country!(s, "GB") }

    fr = heritage_card(s).dig("i18n", "fr")
    # localized_card merges options by position, so keeping the old array would
    # show a French respondent the previous taxonomy's categories.
    refute_equal Array.new(9, "vieux"), fr&.dig("options")
  end

  # ── Cross-cutting registrations ───────────────────────────────────────────

  test "the endpoint is throttled and capped like every other Claude spender" do
    assert_includes SurveysController.ai_throttled_actions, :update_audience_country
    assert_includes SurveysController.ai_capped_actions, :update_audience_country
  end
end
