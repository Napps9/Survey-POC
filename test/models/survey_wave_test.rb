require "test_helper"

class SurveyWaveTest < ActiveSupport::TestCase
  def build_survey(**attrs)
    org = Organisation.create!(name: "Wave Org", slug: "swm-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "S", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: [],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: 5.days.ago, **attrs
    )
  end

  # ── start_next_wave! ────────────────────────────────────────────────────────

  test "the first call materialises wave 1, backfilling every existing response" do
    s = build_survey
    r1 = s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed")
    r2 = s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed")
    refute s.waved?

    s.start_next_wave!

    assert s.waved?
    wave1 = s.survey_waves.find_by(position: 1)
    assert wave1
    refute wave1.open?, "wave 1 must close the moment wave 2 opens"
    assert_equal wave1.opened_at.to_i, s.published_at.to_i
    assert_equal wave1.id, r1.reload.survey_wave_id
    assert_equal wave1.id, r2.reload.survey_wave_id

    wave2 = s.current_wave
    assert_equal 2, wave2.position
    assert wave2.open?
  end

  test "a survey with no responses yet still gets a valid wave 1 (opened_at falls back to created_at)" do
    s = build_survey(published_at: nil)
    s.start_next_wave!
    wave1 = s.survey_waves.find_by(position: 1)
    assert_equal wave1.opened_at.to_i, s.created_at.to_i
  end

  test "positions increment on every subsequent call, closing whatever was open" do
    s = build_survey
    s.start_next_wave! # implicit wave 1 -> wave 2
    s.start_next_wave!(label: "Follow-up") # wave 2 -> wave 3

    positions = s.survey_waves.reload.map(&:position)
    assert_equal [ 1, 2, 3 ], positions
    assert_equal 3, s.current_wave.position
    assert s.survey_waves.where(position: [ 1, 2 ]).none?(&:open?)
    assert_equal "Follow-up", s.survey_waves.find_by(position: 3).label
  end

  test "current_wave is nil until the first call, then always the one open wave" do
    s = build_survey
    assert_nil s.current_wave

    s.start_next_wave!
    assert_equal 2, s.current_wave.position

    s.start_next_wave!
    assert_equal 3, s.current_wave.position
  end

  test "destroying the survey destroys its waves; a response survives with the wave detached" do
    s = build_survey
    resp = s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed")
    s.start_next_wave!
    wave1 = s.survey_waves.find_by(position: 1)
    resp.update!(survey_wave_id: wave1.id)

    wave1.destroy!
    assert_nil resp.reload.survey_wave_id, "the response must survive, only the label detaches"
  end

  # ── wave_returning_count ────────────────────────────────────────────────────

  test "counts a respondent code seen in an earlier wave, ignores blank digests" do
    s = build_survey(respondent_code_enabled: true)
    s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                        respondent_code_digest: s.respondent_code_digest("sam"))
    s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed") # no code
    s.start_next_wave!
    wave2 = s.current_wave

    s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                        respondent_code_digest: s.respondent_code_digest("sam"), survey_wave_id: wave2.id)
    s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                        respondent_code_digest: s.respondent_code_digest("alex"), survey_wave_id: wave2.id)

    assert_equal 1, s.wave_returning_count(wave2)
  end

  test "wave 1 always returns zero — nothing can return before the first wave" do
    s = build_survey(respondent_code_enabled: true)
    s.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                        respondent_code_digest: s.respondent_code_digest("sam"))
    s.start_next_wave!
    wave1 = s.survey_waves.find_by(position: 1)

    assert_equal 0, s.wave_returning_count(wave1)
  end

  # ── SurveyWave ──────────────────────────────────────────────────────────────

  test "display_label falls back to a position-based name" do
    s = build_survey
    s.start_next_wave!
    wave1 = s.survey_waves.find_by(position: 1)
    assert_equal "Wave 1", wave1.display_label

    wave1.update!(label: "Baseline")
    assert_equal "Baseline", wave1.display_label
  end

  test "position is unique per survey" do
    s = build_survey
    s.start_next_wave!
    assert_raises(ActiveRecord::RecordInvalid) { s.survey_waves.create!(position: 2, opened_at: Time.current) }
  end
end
