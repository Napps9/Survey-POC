require "test_helper"

# The optional self-invented code that links one person's answers across waves of
# the same Verto without identifying them.
#
# The whole design rests on one property: the plaintext is never stored. What's
# kept is a per-survey HMAC, so a creator with database access can neither read a
# code nor recognise the same person in another Verto.
class RespondentCodeTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "rc-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "rc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def sign_in!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def survey(enabled: true, **attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ],
                         cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
                         respondent_code_enabled: enabled,
                         publish_token: SecureRandom.urlsafe_base64(18),
                         published_at: Time.current, **attrs)
  end

  def answer!(s, code:, token: SecureRandom.uuid, value: "Yes")
    post progress_survey_path(s.publish_token),
         params: { session_token: token, respondent_code: code, answers: { "0" => { "value" => value } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    s.responses.find_by(session_token: token)
  end

  # ── The privacy property ──────────────────────────────────────────────────

  test "the plaintext is never stored anywhere on the response" do
    s = survey
    resp = answer!(s, code: "sam14")

    assert resp.respondent_code_digest.present?
    assert_not_equal "sam14", resp.respondent_code_digest
    # Nothing anywhere on the row holds it.
    assert_not resp.attributes.values.map(&:to_s).any? { |v| v.include?("sam14") },
               "the code must not survive in any column"
  end

  test "the digest is a real HMAC, not a bare hash of the code" do
    s = survey
    digest = s.respondent_code_digest("sam14")

    assert_equal 64, digest.length
    assert_not_equal Digest::SHA256.hexdigest("sam14"), digest,
                     "an unkeyed hash would be trivially reversible by dictionary"
  end

  test "the same code in two Vertos gives unrelated digests" do
    a = survey
    b = survey
    assert_not_equal a.respondent_code_digest("sam14"), b.respondent_code_digest("sam14"),
                     "a digest must not identify someone across Vertos"
  end

  test "the code is normalised so a person matches themselves" do
    s = survey
    canonical = s.respondent_code_digest("sam14")

    assert_equal canonical, s.respondent_code_digest("SAM14")
    assert_equal canonical, s.respondent_code_digest("  Sam 14 ")
    assert_not_equal canonical, s.respondent_code_digest("sam15")
  end

  test "a blank code is no code, not a digest everyone shares" do
    s = survey
    assert_nil s.respondent_code_digest("")
    assert_nil s.respondent_code_digest("   ")
    assert_nil s.respondent_code_digest(nil)

    resp = answer!(s, code: "   ")
    assert_nil resp.respondent_code_digest
  end

  # Asserted on behaviour rather than on config shape: Rails compiles
  # filter_parameters into regexps, so checking for the symbol proves nothing.
  test "the code is filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    masked = filter.filter("respondent_code" => "sam14", "answers" => { "0" => "Yes" })

    assert_not_equal "sam14", masked["respondent_code"],
                     "the logs must not hold the one plaintext copy the database refuses to keep"
    assert_equal({ "0" => "Yes" }, masked["answers"], "and ordinary answers are still logged")
  end

  # ── Linking across waves ──────────────────────────────────────────────────

  test "the same code across two runs produces two rows sharing a digest" do
    s = survey
    first  = answer!(s, code: "sam14")
    second = answer!(s, code: "Sam 14", value: "No")

    assert_not_equal first.id, second.id, "repeat participation is a new response, not an overwrite"
    assert_equal first.respondent_code_digest, second.respondent_code_digest
    assert_equal 2, s.responses.count
  end

  test "the creator sees a count of returners, never a code" do
    s = survey
    answer!(s, code: "sam14")
    answer!(s, code: "sam14")
    answer!(s, code: "alex7")

    assert_equal 1, s.returning_respondents_count, "one person came back; the other appeared once"
  end

  test "the same code across two waves counts as returning for the later wave" do
    s = survey
    first = answer!(s, code: "sam14")
    s.start_next_wave!
    second = answer!(s, code: "Sam 14", value: "No") # normalises to the same digest

    assert_equal first.reload.respondent_code_digest, second.respondent_code_digest
    wave2 = s.current_wave
    assert_equal wave2.id, second.survey_wave_id, "a response created after start_next_wave! belongs to the new wave"
    assert_equal 1, s.wave_returning_count(wave2)
  end

  test "a different code across two waves is not counted as returning" do
    s = survey
    answer!(s, code: "sam14")
    s.start_next_wave!
    answer!(s, code: "someone-else")

    assert_equal 0, s.wave_returning_count(s.current_wave)
  end

  test "responses answered before any wave existed are retroactively wave 1 once one starts" do
    s = survey
    resp = answer!(s, code: "sam14")
    assert_nil resp.survey_wave_id, "wave 1 stays implicit (nil) until start_next_wave! is first called"

    s.start_next_wave!
    wave1 = s.survey_waves.find_by(position: 1)
    assert_equal wave1.id, resp.reload.survey_wave_id
  end

  test "a code cannot be changed once recorded for a response" do
    s = survey
    token = SecureRandom.uuid
    first = answer!(s, code: "sam14", token: token)
    original = first.respondent_code_digest

    answer!(s, code: "someone-else", token: token, value: "No")
    assert_equal original, s.responses.find_by(session_token: token).respondent_code_digest,
                 "a reload mid-Verto keeps the identity it started with"
  end

  test "nothing is recorded when the feature is off" do
    s = survey(enabled: false)
    resp = answer!(s, code: "sam14")
    assert_nil resp.respondent_code_digest
  end

  # ── Where it surfaces ─────────────────────────────────────────────────────

  test "the player renders the gate, with no answer index of its own" do
    s = survey
    get play_survey_path(s.publish_token)
    assert_response :success

    assert_select "[data-card-type='respondent_code_card']"
    assert_select "[data-card-type='respondent_code_card'][data-card-index]", false,
                  "a pseudo-card must never shift the answer keys"
    assert_select "[data-player-target='respondentCode']"
  end

  test "the gate is absent when the feature is off" do
    s = survey(enabled: false)
    get play_survey_path(s.publish_token)
    assert_select "[data-card-type='respondent_code_card']", false
  end

  test "the creator's own prompt wording is shown, falling back to the default" do
    s = survey(respondent_code_prompt: "Your nickname plus your birth day")
    get play_survey_path(s.publish_token)
    assert_select "[data-card-type='respondent_code_card'] .play-consent-body",
                  text: "Your nickname plus your birth day"

    s.update!(respondent_code_prompt: nil)
    get play_survey_path(s.publish_token)
    # assert_select, not assert_match: the default copy contains an apostrophe,
    # which arrives HTML-escaped in the raw body.
    assert_select "[data-card-type='respondent_code_card'] .play-consent-body",
                  text: I18n.t("player.respondent_code_prompt_default")
  end

  test "update_settings toggles the feature and stores the prompt" do
    sign_in!
    s = survey(enabled: false)

    post survey_settings_path(s), params: { respondent_code_enabled: "1",
                                            respondent_code_prompt: "  Nickname + birth day  " }
    s.reload
    assert s.respondent_code_enabled?
    assert_equal "Nickname + birth day", s.respondent_code_prompt

    post survey_settings_path(s), params: { respondent_code_prompt: "   " }
    assert_nil s.reload.respondent_code_prompt
  end

  # It's a presentation setting, not a scoring one — safe on a live Verto.
  test "it stays editable once the Verto is live" do
    sign_in!
    s = survey(enabled: false)
    s.responses.create!(session_token: SecureRandom.uuid, answers: {}, answered: true, status: "completed")

    post survey_settings_path(s), params: { respondent_code_enabled: "1" }
    assert s.reload.respondent_code_enabled?
  end

  test "the editor offers the toggle and its prompt field" do
    sign_in!
    s = survey
    get survey_path(s)
    assert_response :success
    assert_select "input[name='respondent_code_enabled']"
    assert_select "input[name='respondent_code_prompt']"
  end
end
