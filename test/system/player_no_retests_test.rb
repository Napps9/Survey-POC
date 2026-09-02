require "application_system_test_case"

# "No retests" in the browser — the old no-redo gate never had browser coverage.
# Device basis: a device that finished lands on the thank-you screen on its next
# visit. Code basis: the same code on a NEW device is stopped at the code step
# without a row being written, a new wave admits it again, and a shared device
# gets a "Next person" hand-over that starts a fresh session.
class PlayerNoRetestsTest < ApplicationSystemTestCase
  CODE = "zx91q".freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "nrs-#{SecureRandom.hex(3)}")
  end

  def build_survey(**attrs)
    s = @org.surveys.create!(
      title: "Once", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], no_retests: true,
      cards: [
        { "type" => "multiple_choice", "cid" => "q1", "text" => "How was today?", "options" => [ "Great", "Fine" ] },
        { "type" => "multiple_choice", "cid" => "q2", "text" => "And tomorrow?", "options" => [ "Better", "Same" ] }
      ], **attrs
    )
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s
  end

  # The pre-screen code step (respondent_code_enabled) — the same target and
  # action the in-deck code card binds.
  def enter_code!(code = CODE)
    assert_selector "[data-player-target='respondentCode']", wait: 5
    find("[data-player-target='respondentCode']").set(code)
    find("[data-action='click->player#submitRespondentCode']").click
  end

  def play_through!
    assert_selector ".preview-card.active", wait: 5
    assert_text "How was today?"
    find(".choice-list-item", text: "Great").click
    find(".preview-btn-next").click
    assert_text "And tomorrow?"
    find(".choice-list-item", text: "Better").click
    find(".preview-btn-finish").click
    assert_selector ".preview-thankyou.active", wait: 8
  end

  def session_token
    page.evaluate_script(<<~JS)
      sessionStorage.getItem(`verto_session_${document.querySelector('[data-controller="player"]').dataset.playerSubmitUrlValue}`)
    JS
  end

  test "device basis: a device that finished lands on the thank-you screen next time, with no replay" do
    s = build_survey
    visit "/play/#{s.publish_token}"
    dismiss_cookie_banner
    play_through!
    wait_for_rows(s, 1)
    assert_no_selector ".play-end-btn", text: /Play again|Next person/

    visit "/play/#{s.publish_token}"
    assert_selector ".preview-thankyou.active", wait: 5
    assert_text I18n.t("js.player.already_played_plain")
    assert_no_selector ".preview-card.active"
    assert_no_text "How was today?"
    assert_equal 1, s.responses.reload.count, "the refused visit wrote nothing"
  end

  test "code basis: the same code is stopped at the code step on a new device, and admitted by a new wave" do
    s = build_survey(respondent_code_enabled: true)
    visit "/play/#{s.publish_token}"
    dismiss_cookie_banner
    enter_code!
    play_through!
    first = wait_for_rows(s, 1).first
    assert_equal s.respondent_code_digest(CODE), first.respondent_code_digest
    assert_nil first.player_key_digest, "the code is the identity — no per-device digest on this Verto"

    # A NEW device: cleared storage is exactly what a different phone looks like.
    page.execute_script("localStorage.clear(); sessionStorage.clear()")
    visit "/play/#{s.publish_token}"
    enter_code!
    assert_selector ".preview-thankyou.active", wait: 5
    assert_text I18n.t("js.player.already_played_plain")
    assert_no_text "How was today?"
    assert_equal 1, s.responses.reload.count, "stopped at the code step: no row, no answers"

    # The owner starts the next wave: the post-test is admitted, once.
    s.start_next_wave!
    page.execute_script("localStorage.clear(); sessionStorage.clear()")
    visit "/play/#{s.publish_token}"
    enter_code!
    play_through!
    rows = wait_for_rows(s, 2)
    second = (rows - [ first ]).first
    assert_equal first.respondent_code_digest, second.respondent_code_digest
    assert_equal s.current_wave.id, second.survey_wave_id, "stamped with the wave that admitted it"
  end

  test "Next person hands a shared device to the next pupil with a fresh session" do
    s = build_survey(respondent_code_enabled: true)
    visit "/play/#{s.publish_token}"
    dismiss_cookie_banner
    enter_code!("pupil-a")
    play_through!
    wait_for_rows(s, 1)
    before = session_token
    assert before.present?

    find(".play-end-btn", text: "Next person").click
    assert_selector "[data-player-target='respondentCode']", wait: 5
    assert_not_equal before, session_token, "a fresh session token — the next pupil never writes onto this row"

    enter_code!("pupil-b")
    play_through!
    rows = wait_for_rows(s, 2)
    assert_equal 2, rows.map(&:respondent_code_digest).uniq.size, "two pupils, two rows, two identities"
  end

  private

  def wait_for_rows(survey, count)
    deadline = Time.current + 8
    loop do
      rows = survey.responses.reload.to_a
      return rows if rows.size >= count
      raise "expected #{count} responses, got #{rows.size}" if Time.current > deadline
      sleep 0.2
    end
  end
end
