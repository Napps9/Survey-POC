require "test_helper"

# "No retests": one completed run per identity per wave. This locks the
# identity rule (the respondent code is exclusive wherever a code is collected;
# the device key is only ever the fallback) and the wave scope (implicit wave 1
# is nil, materialised by start_next_wave!). The HTTP refusals built on it are
# covered by no_retests_player_test.
class SurveyRetestTest < ActiveSupport::TestCase
  def build_survey(**attrs)
    org = Organisation.create!(name: "Retest Org", slug: "srt-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "S", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: 5.days.ago,
      no_retests: true, **attrs
    )
  end

  def run!(survey, status: "completed", code: nil, key: nil, wave: :current)
    survey.responses.create!(
      session_token: SecureRandom.uuid, status: status, answered: true,
      completed_at: (status == "completed" ? Time.current : nil),
      respondent_code_digest: (code ? survey.respondent_code_digest(code) : nil),
      player_key_digest: (key ? survey.player_key_digest(key) : nil),
      survey_wave_id: (wave == :current ? survey.current_wave&.id : wave&.id)
    )
  end

  # An unsaved row as the write path builds it, carrying the identities the
  # client just sent.
  def probe(survey, code: nil, key: nil)
    survey.responses.new(
      session_token: SecureRandom.uuid,
      respondent_code_digest: (code ? survey.respondent_code_digest(code) : nil),
      player_key_digest: (key ? survey.player_key_digest(key) : nil)
    )
  end

  # ── The basis ──────────────────────────────────────────────────────────────

  test "no basis while the rule is off, the code wherever one is collected, else the device" do
    assert_nil build_survey(no_retests: false).retest_basis
    assert_nil build_survey(no_retests: false, respondent_code_enabled: true).retest_basis

    assert_equal "device", build_survey.retest_basis
    assert_equal "code", build_survey(respondent_code_enabled: true).retest_basis

    card_only = build_survey(cards: [ { "type" => "respondent_code", "cid" => "rc", "text" => "Code" },
                                      { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])
    assert_not card_only.respondent_code_enabled?
    assert_equal "code", card_only.retest_basis, "a card collects the code just as the pre-screen does"
  end

  test "the device identity is minted only when it is the basis" do
    assert build_survey.player_identity_active?, "no code collected: the device is all there is to check"
    assert_not build_survey(respondent_code_enabled: true).player_identity_active?,
               "a code-collecting Verto must not start minting per-device digests"
    assert_not build_survey(no_retests: false).player_identity_active?
  end

  # ── Code basis ─────────────────────────────────────────────────────────────

  test "a completed run under the same code in the same (implicit) wave blocks" do
    s = build_survey(respondent_code_enabled: true)
    run!(s, code: "sam14")

    assert s.retest_blocked?(probe(s, code: "sam14"))
    assert s.retest_blocked?(probe(s, code: " SAM14 ")), "normalised like every other code comparison"
    assert_not s.retest_blocked?(probe(s, code: "zx91q"))
  end

  test "an unfinished run never blocks" do
    s = build_survey(respondent_code_enabled: true)
    run!(s, code: "sam14", status: "started")

    assert_not s.retest_blocked?(probe(s, code: "sam14"))
  end

  test "a row with no identity is never matched — nil must not become IS NULL" do
    s = build_survey(respondent_code_enabled: true)
    run!(s) # completed, no code, no key

    assert_not s.retest_blocked?(probe(s))
    assert_not s.retest_blocked?(probe(s, code: "sam14"))
  end

  test "the code is exclusive: a different code on the same device is admitted" do
    s = build_survey(respondent_code_enabled: true)
    run!(s, code: "pupil-a", key: "classroom-tablet")

    assert_not s.retest_blocked?(probe(s, code: "pupil-b", key: "classroom-tablet")),
               "the shared classroom tablet: pupil B must not be refused for pupil A's run"
    assert s.retest_blocked?(probe(s, code: "pupil-a", key: "another-device")),
           "and pupil A is refused on any device"
  end

  test "the row being written is excluded, so a replay of its own submit is idempotent" do
    s = build_survey(respondent_code_enabled: true)
    own = run!(s, code: "sam14")

    assert_not s.retest_blocked?(own)
  end

  # ── Device basis ───────────────────────────────────────────────────────────

  test "without codes the device key is the identity and the code is ignored" do
    s = build_survey
    run!(s, key: "phone-1", code: "ignored")

    assert s.retest_blocked?(probe(s, key: "phone-1"))
    assert_not s.retest_blocked?(probe(s, key: "phone-2", code: "ignored"))
    assert_not s.retest_blocked?(probe(s))
  end

  # ── Waves ──────────────────────────────────────────────────────────────────

  test "starting the next wave re-admits everyone, once" do
    s = build_survey(respondent_code_enabled: true)
    run!(s, code: "sam14")
    assert s.retest_blocked?(probe(s, code: "sam14"))

    s.start_next_wave!
    assert_not s.retest_blocked?(probe(s, code: "sam14")), "the post-test is admitted"

    run!(s, code: "sam14") # stamped with wave 2
    assert s.retest_blocked?(probe(s, code: "sam14")), "and refused a second time within wave 2"

    wave1 = s.survey_waves.find_by(position: 1)
    assert_equal 1, s.responses.where(survey_wave_id: wave1.id).count, "wave 1 rows stay where they were"
  end

  test "a decline purge drops both identities, so re-agreeing is admitted" do
    s = build_survey(respondent_code_enabled: true)
    row = run!(s, code: "sam14", key: "k")
    row.purge_for_declined_consent!
    row.save!

    assert_not s.retest_blocked?(probe(s, code: "sam14", key: "k"))
  end
end
