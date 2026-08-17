require "application_system_test_case"

# results-autorefresh turns the live tally's broadcast into a throttled
# reload of the results-feed frame — opt-in, off by default (see the
# controller's own comment for why). The timer itself is 45s, far too long
# to wait on in a system test, so these drive the controller's public
# behaviour directly (its toggle, and the same markDirty + tick a real
# broadcast would trigger) rather than a real interval or a real Action
# Cable round trip.
class ResultsAutorefreshTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "O", slug: "ar-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "ar-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "AR", theme: "Th", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] } ]
    )
  end

  def open_results
    sign_in_as(@user)
    visit survey_results_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-controller~='results-autorefresh']", wait: 5
  end

  def ctrl_state
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-controller~='results-autorefresh']")
        const app = window.Stimulus || window.application
        const ctrl = app.getControllerForElementAndIdentifier(el, "results-autorefresh")
        return { on: ctrl._on }
      })()
    JS
  end

  # The same signal a real ResultsActivity broadcast produces (turbo:before-
  # stream-render on the results-live replace) plus an immediate tick —
  # standing in for waiting out the real 45s interval.
  def mark_dirty_and_tick
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-controller~='results-autorefresh']")
        const app = window.Stimulus || window.application
        const ctrl = app.getControllerForElementAndIdentifier(el, "results-autorefresh")
        ctrl._dirty = true
        ctrl._tick()
      })()
    JS
  end

  def frame_src
    evaluate_script("document.getElementById('results-feed')?.getAttribute('src') || ''")
  end

  test "the toggle turns auto-refresh on and off, persisted in localStorage" do
    open_results
    assert_equal false, ctrl_state["on"], "must default off"

    find("[data-results-autorefresh-target='toggle']").click
    assert_equal true, ctrl_state["on"]
    assert_equal "1", evaluate_script("localStorage.getItem('resultsAutorefresh')")
    assert_text "Auto ↻ on"

    find("[data-results-autorefresh-target='toggle']").click
    assert_equal false, ctrl_state["on"]
    assert_text "Auto ↻ off"
  end

  test "a broadcast signal reloads the frame only once the toggle is on" do
    open_results

    mark_dirty_and_tick
    sleep 0.2
    assert_equal "", frame_src, "off by default — a dirty signal must not reload the frame"

    find("[data-results-autorefresh-target='toggle']").click
    mark_dirty_and_tick
    assert_equal survey_results_path(@survey, segment: "overall"), frame_src
  end

  test "an open AI-report modal blocks the reload; it still lands once closed" do
    open_results
    find("[data-results-autorefresh-target='toggle']").click

    find("button[data-action='click->report-export#open']").click
    assert_selector ".report-modal:not(.hidden)", wait: 3

    mark_dirty_and_tick
    sleep 0.2
    assert_equal "", frame_src, "must not reload while the report modal is open"

    # The Ask Verto sidebar overlaps the modal's top-right corner on this
    # viewport (pre-existing, unrelated to this feature) — trigger rather
    # than click, per Cuprite's own suggestion for a known overlap.
    find(".report-modal-x").trigger("click")
    assert_selector ".report-modal.hidden", wait: 3, visible: false
    # _dirty was never cleared by the blocked attempt, so the next tick
    # (a real one would arrive on the following interval) delivers it.
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-controller~='results-autorefresh']")
        const app = window.Stimulus || window.application
        app.getControllerForElementAndIdentifier(el, "results-autorefresh")._tick()
      })()
    JS
    assert_equal survey_results_path(@survey, segment: "overall"), frame_src
  end
end
