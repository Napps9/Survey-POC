require "test_helper"

# Waves as ResolvesResultSegments entries: the one seam that's supposed to
# feed results pills, compare, exports and summaries automatically. See
# app/controllers/concerns/resolves_result_segments.rb.
class ResultsWavesTest < ActionDispatch::IntegrationTest
  include ResolvesResultSegments

  def setup
    @user = User.create!(name: "U", email_address: "rw-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "rw-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: 10.days.ago
    )
  end

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def segment_ids
    base, segments, = resolve_result_segments(@survey, nil)
    [ base, segments ]
  end

  # answered is recomputed from `answers` content by Response's own
  # before_save (sync_answered) — an explicit answered: true alone is
  # overwritten back to false with no answers hash to back it up, same
  # fixture shape results_filters_test.rb already uses.
  ANSWERS = { "0" => { "value" => "Blue" } }.freeze

  test "no wave segments exist until the survey has been waved" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS)
    _base, segments = segment_ids
    refute segments.any? { |s| s[:id].to_s.start_with?("wave_") }
  end

  test "a single response before any wave counts under wave 1 once waved" do
    resp = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS)
    @survey.start_next_wave!

    _base, segments = segment_ids
    wave1 = segments.find { |s| s[:id] == "wave_1" }
    assert wave1
    assert_equal 1, wave1[:count]
    assert_includes wave1[:scope], resp.reload
  end

  test "a wave with zero responses still appears — no small-cell suppression" do
    @survey.start_next_wave! # wave 1 implicit, wave 2 opens with nothing in it yet

    _base, segments = segment_ids
    wave2 = segments.find { |s| s[:id] == "wave_2" }
    assert wave2, "a freshly-opened wave must be a visible segment even at zero"
    assert_equal 0, wave2[:count]
  end

  test "even a single respondent forms its own wave segment (unlike regions/demographics)" do
    @survey.start_next_wave!
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS,
                              survey_wave_id: @survey.current_wave.id)

    _base, segments = segment_ids
    wave2 = segments.find { |s| s[:id] == "wave_2" }
    assert_equal 1, wave2[:count]
  end

  test "each wave counts only its own responses, not the whole Verto" do
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS)
    @survey.start_next_wave!
    2.times { @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS, survey_wave_id: @survey.current_wave.id) }

    _base, segments = segment_ids
    assert_equal 1, segments.find { |s| s[:id] == "wave_1" }[:count]
    assert_equal 2, segments.find { |s| s[:id] == "wave_2" }[:count]
    assert_equal 3, segments.find { |s| s[:id] == "overall" }[:count]
  end

  test "the results page renders the wave-over-wave strip once there are 2+ waves, not before" do
    sign_in
    @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                              answers: { "0" => { "value" => "Blue" } })

    get survey_results_path(@survey)
    assert_response :success
    refute_match "Wave over wave", response.body

    @survey.start_next_wave!
    @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                              answers: { "0" => { "value" => "Green" } }, survey_wave_id: @survey.current_wave.id)

    get survey_results_path(@survey)
    assert_response :success
    assert_match "Wave over wave", response.body
    assert_match "Wave 1", response.body
    assert_match "Wave 2", response.body
  end

  test "the wave strip shows the returning-respondent count for a wave" do
    sign_in
    @survey.update!(respondent_code_enabled: true)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS,
                              respondent_code_digest: @survey.respondent_code_digest("sam"))
    @survey.start_next_wave!
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: ANSWERS,
                              respondent_code_digest: @survey.respondent_code_digest("sam"),
                              survey_wave_id: @survey.current_wave.id)

    get survey_results_path(@survey)
    assert_response :success
    assert_match "1 returner", response.body
  end

  test "the wave strip shows a baseline-vs-latest headline delta for a choice question" do
    sign_in
    3.times { @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed", answers: { "0" => { "value" => "Blue" } }) }
    @survey.start_next_wave!
    wave2 = @survey.current_wave
    3.times { @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed", answers: { "0" => { "value" => "Green" } }, survey_wave_id: wave2.id) }

    get survey_results_path(@survey)
    assert_response :success
    # Baseline: 100% Blue. Latest: 0% Blue (all Green). Delta -100pp.
    assert_match "-100pp", response.body
  end

  test "the wave strip and its date/segment filters are independent — a date range doesn't hide old waves" do
    sign_in
    @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                              answers: { "0" => { "value" => "Blue" } }, created_at: 60.days.ago, updated_at: 60.days.ago)
    @survey.start_next_wave!
    @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                              answers: { "0" => { "value" => "Green" } }, survey_wave_id: @survey.current_wave.id)

    get survey_results_path(@survey, range: "7d")
    assert_response :success
    # The 60-day-old wave 1 response would fall outside a 7-day window, but
    # the wave strip is deliberately whole-Verto, same as the leaderboard.
    assert_match "Wave over wave", response.body
    assert_match "Wave 1", response.body
  end

  test "an owner (not admin) can still start a wave — it's a presentation-tier action" do
    member = User.create!(name: "M", email_address: "rw2-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: member, role: "member")
    post session_path, params: { email_address: member.email_address, password: "verylongpassword" }

    post survey_waves_path(@survey)
    assert @survey.reload.waved?
  end

  test "a never-published draft refuses to start a wave" do
    sign_in
    draft = @org.surveys.create!(title: "D", theme: "T", audience_age: "all", key_insight: "x",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    refute draft.published_at.present?

    post survey_waves_path(draft)
    refute draft.reload.waved?
  end

  test "another org's survey is not reachable" do
    other = User.create!(name: "O2", email_address: "rw3-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    Organisation.create!(name: "Other", slug: "rw3-#{SecureRandom.hex(3)}")
                .memberships.create!(user: other, role: "admin")
    post session_path, params: { email_address: other.email_address, password: "verylongpassword" }

    post survey_waves_path(@survey)
    assert_response :not_found
    refute @survey.reload.waved?
  end

  test "starting a wave never locks editing — it's metadata, not deck structure" do
    sign_in
    @survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed")
    assert @survey.editing_locked? # already locked (published + has responses) before any wave

    post survey_waves_path(@survey)
    assert @survey.reload.waved?
    assert @survey.editing_locked?, "starting a wave must not be what locks or unlocks editing"
  end

  test "renaming a wave persists the label and redirects back to the editor" do
    sign_in
    @survey.start_next_wave!
    wave1 = @survey.survey_waves.find_by(position: 1)

    patch survey_wave_path(@survey, wave1), params: { label: "Baseline" }
    assert_redirected_to survey_path(@survey, panel: "publish")
    assert_equal "Baseline", wave1.reload.label
  end

  test "a blank rename clears the label back to the position fallback" do
    sign_in
    @survey.start_next_wave!(label: "Kickoff")
    wave2 = @survey.current_wave

    patch survey_wave_path(@survey, wave2), params: { label: "   " }
    assert_nil wave2.reload.label
    assert_equal "Wave 2", wave2.reload.display_label
  end
end
