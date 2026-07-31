require "application_system_test_case"

# BUG-027. `_gradeRemote` returned bare `null` on any failure and `_gradeCurrent`
# silently returned on a falsy result. So when the Verto closed mid-quiz, or the
# respondent lost signal, tapping "Check answer" did **nothing at all** — no
# error, no hint, no spinner left behind. The button looked broken, the
# respondent could not move on, and nothing was saved.
#
# The comment on that line said "couldn't grade — allow a retry", which was true
# and useless: a retry was allowed but never suggested, and nothing on screen
# distinguished it from a dead button.
class QuizGradeFailureTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "qg-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Qg", email_address: "qg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Quiz", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], quiz: true,
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "multiple_choice", "cid" => "q1", "text" => "Capital of France?",
          "options" => [ "Paris", "Rome" ], "correct" => "Paris" }
      ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def play
    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    assert_selector "[data-player-target='card']", minimum: 1
  end

  # Answer the graded card and ask the controller to grade it, the way the
  # Next/Check button does.
  def answer_and_check
    execute_script(<<~JS)
      const app  = window.Stimulus || window.application
      const root = document.querySelector('[data-controller~="player"]')
      const c    = app.getControllerForElementAndIdentifier(root, "player")
      const card = document.querySelector("[data-card-cid='q1']")
      const idx  = c.cardTargets.indexOf(card)
      c.currentValue = idx
      c._update() // actually show the card, or its error note is never visible
      c._answers[card.dataset.cardIndex] = { type: "multiple_choice", value: "Paris" }
      c._gradeCurrent()
    JS
  end

  test "a closed Verto says so instead of doing nothing" do
    play
    @survey.update_columns(unpublished_at: Time.current)

    answer_and_check

    assert_selector ".quiz-grade-error", wait: 5
    assert_text "This Verto has closed"
  end

  test "a network failure invites a retry" do
    play
    execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    answer_and_check

    assert_selector ".quiz-grade-error", wait: 5
  end

  test "the card stays retryable after a failure" do
    # _revealed is what stops a double-tap re-submitting. A failed grade must
    # release it, or the respondent is locked out of their own retry.
    play
    @survey.update_columns(unpublished_at: Time.current)
    answer_and_check
    assert_selector ".quiz-grade-error", wait: 5

    revealed = evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="player"]')
        const c    = app.getControllerForElementAndIdentifier(root, "player")
        return c._revealed.size
      })()
    JS
    assert_equal 0, revealed, "a failed grade must not leave the card marked as revealed"
  end

  # The negative case: a grade that works must not show an error, or the note
  # would appear on every correctly-graded answer.
  test "a successful grade shows no error" do
    play
    answer_and_check

    assert_no_selector ".quiz-grade-error", wait: 3
  end

  test "a stale error clears when the retry succeeds" do
    play
    execute_script("window.__real = window.fetch; window.fetch = () => Promise.reject(new Error('offline'))")
    answer_and_check
    assert_selector ".quiz-grade-error", wait: 5

    execute_script("window.fetch = window.__real")
    answer_and_check

    assert_no_selector ".quiz-grade-error", wait: 5
  end
end
