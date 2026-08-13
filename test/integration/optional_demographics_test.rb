require "test_helper"

# The opt-in demographic questions (Heritage, Neurodiversity) end to end:
# answers denormalise into their columns under the same tamper-guard posture
# as gender, the multi-select packing + exclusivity rules hold, the gender
# sync survives sharing a deck with another demographic multiple_choice (the
# collision this feature's demographic_key exists to prevent), and results
# grow the new segment pills with small-cell suppression.
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
             [ DemographicQuestions.optional_card("heritage"),
               DemographicQuestions.optional_card("neurodiversity") ]
    )
    @survey.update!(publish_token: SecureRandom.hex(8))
    # Deck: 0 yes_no · 1 birth · 2 location · 3 gender · 4 heritage · 5 neuro
  end

  def submit!(answers)
    post submit_survey_path(@survey.publish_token),
         params: { answers: answers }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success
    @survey.responses.order(:id).last
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

  test "neurodiversity packs sorted, pipe-wrapped canonical labels" do
    resp = submit!({ "5" => { "type" => "select_many", "value" => [ "Dyslexia", "ADHD" ] } })
    assert_equal "|ADHD|Dyslexia|", resp.demographic_neurodiversity
  end

  test "real conditions beat the exclusive picks; exclusives store alone" do
    resp = submit!({ "5" => { "type" => "select_many", "value" => [ "ADHD", "None of these" ] } })
    assert_equal "|ADHD|", resp.demographic_neurodiversity

    resp = submit!({ "5" => { "type" => "select_many", "value" => [ "None of these" ] } })
    assert_equal "|None of these|", resp.demographic_neurodiversity

    resp = submit!({ "5" => { "type" => "select_many", "value" => [ "None of these", "Prefer not to say" ] } })
    assert_equal "|None of these|", resp.demographic_neurodiversity, "first-picked exclusive wins, alone"
  end

  test "tampered neurodiversity values are dropped" do
    resp = submit!({ "5" => { "type" => "select_many", "value" => [ "ADHD", "Fake condition", "x|y" ] } })
    assert_equal "|ADHD|", resp.demographic_neurodiversity
  end

  # The neurodiversity card lost its "Another form of neurodivergence" button
  # for the same reason heritage lost "Another heritage": it recorded that
  # someone didn't fit without asking what they are.
  test "a typed neurodivergence packs under the canonical label" do
    resp = submit!({ "5" => { "type" => "select_many", "value" => nil, "other" => "Misophonia" } })

    assert_equal "|Another form of neurodivergence|", resp.demographic_neurodiversity,
                 "otherwise the people the list missed vanish from the segments"
    refute_match(/Misophonia/, resp.demographic_neurodiversity.to_s,
                 "a respondent's own words must never become a dashboard segment label")
    assert_equal "Misophonia", resp.answers["5"]["other"]
  end

  test "a typed neurodivergence beats an exclusive pick" do
    # The Other box replaces the selection platform-wide, so this is really a
    # tampered payload — but if it ever arrives, a real condition wins, exactly
    # as a ticked one does.
    resp = submit!({ "5" => { "type" => "select_many",
                              "value" => [ "None of these" ], "other" => "Misophonia" } })
    assert_equal "|Another form of neurodivergence|", resp.demographic_neurodiversity
  end

  test "a typed answer is ignored on a card that doesn't offer the box" do
    # Decks inserted before the box existed carry 9 options and no allow_other.
    legacy = @survey.cards.dup
    legacy[5] = legacy[5].except("allow_other")
    @survey.update!(cards: legacy)

    resp = submit!({ "5" => { "type" => "select_many", "value" => nil, "other" => "Misophonia" } })
    assert_nil resp.demographic_neurodiversity
  end

  test "heritage and neurodiversity segments appear at the sample floor and overlap correctly" do
    5.times do
      submit!({ "4" => { "type" => "multiple_choice", "value" => "Mixed or multiple heritage" },
                "5" => { "type" => "select_many", "value" => [ "ADHD", "Dyslexia" ] } })
    end
    4.times { submit!({ "5" => { "type" => "select_many", "value" => [ "Autism" ] } }) }
    @survey.responses.update_all(status: "completed")

    segments = result_segments(@survey, @survey.responses)
    ids = segments.map { |s| s[:id] }

    assert_includes ids, "heritage_mixed-or-multiple-heritage"
    assert_includes ids, "neuro_adhd"
    assert_includes ids, "neuro_dyslexia"
    refute_includes ids, "neuro_autism", "4 responders sits under the small-cell floor"

    adhd = segments.find { |s| s[:id] == "neuro_adhd" }
    dyslexia = segments.find { |s| s[:id] == "neuro_dyslexia" }
    assert_equal 5, adhd[:count]
    assert_equal 5, dyslexia[:count], "a two-condition respondent belongs to both segments"
    assert_equal 5, adhd[:scope].count
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
