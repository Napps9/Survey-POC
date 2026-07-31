require "application_system_test_case"

# BUG-019. `_doSave` cleared `_dirty` after awaiting its response, so an edit
# made while a save was in flight was marked clean by the save that did not
# contain it.
#
# markDirty re-arms the 1.5s timer, so on its own that only delays the edit —
# the loss needs the page to go away inside that window. `flushSave`, the
# pagehide/visibilitychange safety net, starts with `if (!this._dirty) return`,
# so a tab closed in that gap took the edit with it. Typing something and
# immediately switching tabs is an ordinary thing to do.
#
# The race is made deterministic here by holding the PATCH open from the test
# rather than by sleeping and hoping — a timing-dependent version of this would
# pass on a fast machine whether or not the bug was fixed.
class AutosaveRaceTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "rc-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Rc", email_address: "rc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Race", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Hello" },
                                     { "type" => "yes_no", "cid" => "q1", "text" => "First?",
                                       "options" => %w[Yes No] }
                                   ])
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "First?"
  end

  # Hold every PATCH open until the test releases it, so "while the save is in
  # flight" is a state we control rather than a window we race.
  def install_gated_fetch
    execute_script(<<~JS)
      window.__gate = { release: null, started: false }
      const real = window.fetch
      window.__realFetch = real
      window.fetch = function (url, opts) {
        if (opts && opts.method === "PATCH") {
          window.__gate.started = true
          return new Promise((resolve, reject) => {
            window.__gate.release = () => real(url, opts).then(resolve, reject)
          })
        }
        return real.apply(this, arguments)
      }
    JS
  end

  def retitle(text)
    execute_script(<<~JS)
      const el = document.querySelector("[data-survey-editor-target='vertoTitle']")
      el.textContent = #{text.to_json}
      el.dispatchEvent(new Event("input", { bubbles: true }))
    JS
  end

  def editor_dirty?
    evaluate_script(<<~JS)
      (() => {
        const root = document.querySelector('[data-controller~="survey-editor"]')
        const app  = window.Stimulus || window.application
        return !!app.getControllerForElementAndIdentifier(root, "survey-editor")._dirty
      })()
    JS
  end

  test "an edit made while a save is in flight is not marked clean by that save" do
    open_editor
    install_gated_fetch

    retitle("First edit")
    wait_for_js("window.__gate.started", seconds: 10)

    # The second edit lands while the first save is still out.
    retitle("Second edit")
    assert editor_dirty?, "precondition: the second edit should mark the editor dirty"

    # Let the first save finish. It carried "First edit", not "Second edit".
    execute_script("window.__gate.release()")
    Timeout.timeout(10) { sleep 0.1 until @survey.reload.title == "First edit" }

    assert editor_dirty?,
           "the completed save carried the FIRST edit, so it must not mark the second one clean " \
           "— flushSave skips when _dirty is false, which is how the edit was lost"
  end

  # The consequence, end to end: with _dirty wrongly cleared, the unload flush
  # no-ops and the edit never reaches the server at all.
  test "the unload flush still sends an edit made during a save" do
    open_editor
    install_gated_fetch

    retitle("First edit")
    wait_for_js("window.__gate.started", seconds: 10)
    retitle("Second edit")

    execute_script("window.__gate.release()")
    Timeout.timeout(10) { sleep 0.1 until @survey.reload.title == "First edit" }

    # What pagehide/visibilitychange would do — and ONLY that. The debounced
    # timer is cancelled first: leaving it armed made an earlier version of this
    # test pass against the unfixed build, because the ordinary save landed the
    # edit and flushSave was never the thing under test.
    execute_script(<<~JS)
      const root = document.querySelector('[data-controller~="survey-editor"]')
      const app  = window.Stimulus || window.application
      const c    = app.getControllerForElementAndIdentifier(root, "survey-editor")
      clearTimeout(c._saveTimer)
      window.fetch = window.__realFetch
      c.flushSave()
    JS

    Timeout.timeout(10) { sleep 0.1 until @survey.reload.title == "Second edit" }
    assert_equal "Second edit", @survey.reload.title
  end

  def wait_for_js(expression, seconds: 5)
    Timeout.timeout(seconds) { sleep 0.05 until evaluate_script("(() => !!(#{expression}))()") }
  rescue Timeout::Error
    flunk "timed out waiting for: #{expression}"
  end
end
