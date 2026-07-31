require "application_system_test_case"

# BUG-020. A respondent finishing a Verto that closed while they had the page
# open was told "Saved — will sync when you're back online", and their answers
# went into IndexedDB to be retried forever.
#
# Two halves conspired. The service worker treated ANY non-2xx as offline, so a
# 410 Gone came back to the page as a synthesised 202 `{ok: true, queued: true}`
# — and `drainQueue` only deleted an item on `res.ok`, so the 410 was retried on
# every same-origin GET for the life of the browser profile. The player then had
# no way to tell a refusal from a queue: `if (!res.ok) throw` sent both to one
# `catch` whose only question was `navigator.onLine`.
#
# The player's half is what a respondent actually experiences, so that is what
# is tested here. The service worker is not registered in the test environment
# (it needs a secure context and a real registration), so the refusal is
# delivered directly — which is exactly what the fixed worker now does.
class SubmitRejectedTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "sr-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Sr", email_address: "sr-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Closing", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "Hello" },
               { "type" => "yes_no", "cid" => "q1", "text" => "Ok?", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def visit_player
    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    assert_selector "[data-player-target='card']", minimum: 1
  end

  # Drives the controller's own finalise path rather than tapping through the
  # deck, so the assertion is about what happens to a refused submit rather than
  # about deck navigation.
  def finalise
    execute_script(<<~JS)
      const root = document.querySelector('[data-controller~="player"]')
      const app  = window.Stimulus || window.application
      app.getControllerForElementAndIdentifier(root, "player")._finalize()
    JS
  end

  test "a refused submit tells the respondent their answers were not saved" do
    visit_player
    # Closed after the respondent loaded the page — the ordinary case, since the
    # player HTML is served stale-while-revalidate.
    @survey.update_columns(unpublished_at: Time.current)

    finalise

    assert_selector ".preview-queued-pill.is-rejected", wait: 5
    assert_text "This Verto has closed"
  end

  test "a successful submit shows no pill at all" do
    # The negative case. Without it the pill could render unconditionally and
    # the test above would still pass, while every respondent who finished
    # normally was told their answers had not been saved.
    visit_player
    finalise

    assert_no_selector ".preview-queued-pill", wait: 3
    assert_equal 1, @survey.reload.responses.count
  end

  test "a refused submit stores nothing" do
    visit_player
    @survey.update_columns(unpublished_at: Time.current)

    finalise
    assert_selector ".preview-queued-pill.is-rejected", wait: 5

    assert_equal 0, @survey.reload.responses.where(status: "completed").count,
                 "a refused submit must not leave a completed response behind"
  end
end
