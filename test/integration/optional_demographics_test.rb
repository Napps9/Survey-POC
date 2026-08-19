require "test_helper"

# The opt-in demographic question (Heritage) end to end: answers denormalise
# into its column under the same tamper-guard posture as gender, the gender sync
# survives sharing a deck with another demographic multiple_choice (the
# collision this feature's demographic_key exists to prevent), and results grow
# the segment pills with small-cell suppression.
class OptionalDemographicsTest < ActionDispatch::IntegrationTest
  include ResolvesResultSegments

  def setup
    @org  = Organisation.create!(name: "OD", slug: "od-#{SecureRandom.hex(2)}")
    @user = User.create!(name: "U", email_address: "od-#{SecureRandom.hex(2)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Fun?" } ] +
             DemographicQuestions.cards +
             [ DemographicQuestions.optional_card("heritage") ]
    )
    @survey.update!(publish_token: SecureRandom.hex(8))
    # Deck: 0 yes_no · 1 birth · 2 location · 3 gender · 4 heritage
  end

  def submit!(answers)
    post submit_survey_path(@survey.publish_token),
         params: { answers: answers }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success
    @survey.responses.order(:id).last
  end

  # A deck inserted before an option was retired: the card carries the full
  # vocabulary as real options, which is what its stored answers validate
  # against. The rules that sort those answers have to outlive the option.
  def with_legacy_options!(idx, key)
    cards = @survey.cards.dup
    cards[idx] = cards[idx].merge("options" => DemographicQuestions.translated_options(key))
    @survey.update!(cards: cards)
  end

  test "a heritage answer denormalises; a tampered one is refused" do
    resp = submit!({ "4" => { "type" => "multiple_choice", "value" => "Asian heritage" } })
    assert_equal "Asian heritage", resp.demographic_heritage

    resp = submit!({ "4" => { "type" => "multiple_choice", "value" => "<script>alert(1)</script>" } })
    assert_nil resp.demographic_heritage,
               "only options the card actually offers may become segment labels"
  end

  # A country-tailored card has no "Another heritage" button — someone whose
  # heritage isn't among the five types it instead. That has to still count.
  test "a typed heritage counts as Another heritage, and never as itself" do
    tailored = DemographicQuestions.country_heritage_card(
      country: "GB", five: [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ]
    )
    @survey.update!(cards: @survey.cards.first(4) + [ tailored, @survey.cards.last ])

    resp = submit!({ "4" => { "type" => "multiple_choice", "value" => nil, "other" => "Cornish" } })

    assert_equal "Another heritage", resp.demographic_heritage,
                 "without this the people the tailored list missed vanish from the segments"
    refute_equal "Cornish", resp.demographic_heritage,
                 "a respondent's own words must never become a dashboard segment label"
    assert_equal "Cornish", resp.answers["4"]["other"],
                 "their words are kept on the answer, for the free-text panel and the exports"
  end

  test "a typed heritage is ignored on a card that doesn't offer the box" do
    # Decks inserted before the box existed carry the old 9 options and no
    # allow_other. A typed payload against one of those is tampering, and the
    # card's own shape is what says so.
    legacy = @survey.cards.dup
    legacy[4] = legacy[4].except("allow_other")
    @survey.update!(cards: legacy)

    resp = submit!({ "4" => { "type" => "multiple_choice", "value" => nil, "other" => "Cornish" } })
    assert_nil resp.demographic_heritage
  end

  test "gender still syncs with heritage in the deck — the collision guard" do
    resp = submit!({ "3" => { "type" => "multiple_choice", "value" => "Female" },
                     "4" => { "type" => "multiple_choice", "value" => "Indigenous heritage" } })

    assert_equal "Female", resp.demographic_gender,
                 "the keyless tail card must keep the gender slot"
    assert_equal "Indigenous heritage", resp.demographic_heritage
  end

  test "heritage segments appear at the sample floor and suppress below it" do
    5.times do
      submit!({ "4" => { "type" => "multiple_choice", "value" => "Mixed or multiple heritage" } })
    end
    4.times { submit!({ "4" => { "type" => "multiple_choice", "value" => "Asian heritage" } }) }
    @survey.responses.update_all(status: "completed")

    segments = result_segments(@survey, @survey.responses)
    ids = segments.map { |s| s[:id] }

    assert_includes ids, "heritage_mixed-or-multiple-heritage"
    refute_includes ids, "heritage_asian-heritage", "4 responders sits under the small-cell floor"

    mixed = segments.find { |s| s[:id] == "heritage_mixed-or-multiple-heritage" }
    assert_equal 5, mixed[:count]
    assert_equal 5, mixed[:scope].count
  end

  test "the results page renders the new pills" do
    # "Another heritage" is no longer a button — it is what a TYPED answer is
    # recorded as. The pill it produces is unchanged, which is the whole reason
    # the label was kept rather than retired: these roll up with the answers
    # collected back when it was still an option.
    5.times { submit!({ "4" => { "type" => "multiple_choice", "value" => nil, "other" => "Cornish" } }) }
    @survey.responses.update_all(status: "completed")

    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    get survey_results_path(@survey)

    assert_response :success
    assert_match "👥 Another heritage", response.body
  end
end
