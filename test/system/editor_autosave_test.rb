require "application_system_test_case"

# Browser coverage for the editor (P2-5 named it as the biggest remaining gap).
#
# The editor is the one surface where a browser test earns its keep most: its
# source of truth is the DOM. `serialize()` rebuilds the cards array by reading
# live markup on every autosave, and new card markup is minted server-side via
# POST /surveys/:id/render_card — there is no render-from-JSON path. An
# integration test can assert what the server does with a payload, but only a
# browser can tell you whether the DOM the editor reads produces that payload.
#
# Deliberately avoids anything that calls Claude: system tests run the real
# server, so an AI path would need a live key rather than the suite's stubs.
class EditorAutosaveTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Hello" },
    { "type" => "yes_no", "cid" => "c1", "text" => "Do you feel safe here?",
      "options" => %w[Yes No] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "ed-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Ed", email_address: "ed-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Original Name", theme: "Safety",
                                   audience_age: "adults", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ], cards: CARDS)
  end

  test "the editor opens and shows the deck" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner

    assert_text "Do you feel safe here?"
  end

  test "renaming a Verto autosaves without a page reload" do
    # The rename plumbing was inert for a long time: serialize() returned
    # titleValue and nothing ever reassigned it. This is what proves the
    # contenteditable title actually reaches the server.
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner

    title = find("[data-survey-editor-target='vertoTitle']")
    title.click
    # Replace the text through the DOM, then fire the input event the editor
    # listens for — typing into a contenteditable is driver-dependent, and what
    # matters here is the save path, not the keystrokes.
    execute_script(<<~JS)
      const el = document.querySelector("[data-survey-editor-target='vertoTitle']")
      el.textContent = "Renamed In Browser"
      el.dispatchEvent(new Event("input", { bubbles: true }))
      el.blur()
    JS

    # Autosave is debounced; wait on the database rather than on a fixed sleep.
    assert_changes -> { @survey.reload.title }, from: "Original Name", to: "Renamed In Browser" do
      Timeout.timeout(10) do
        sleep 0.25 until @survey.reload.title == "Renamed In Browser"
      end
    end
  end

  test "a blank rename is refused rather than saved" do
    # Losing a Verto's name to a stray select-all-delete would be a bad way to
    # find out autosave is eager.
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner

    execute_script(<<~JS)
      const el = document.querySelector("[data-survey-editor-target='vertoTitle']")
      el.textContent = "   "
      el.dispatchEvent(new Event("input", { bubbles: true }))
      el.blur()
    JS

    sleep 2
    assert_equal "Original Name", @survey.reload.title,
                 "a blank title must not overwrite the Verto's name"
  end

  # A keepalive request is the only kind that outlives the page, and the Fetch
  # spec caps its body at 64KB — the browser rejects anything larger, and does
  # it asynchronously, so the `try` that used to wrap the fetch never saw it.
  # flushSave had already cleared _dirty, so a creator on a long or multilingual
  # deck who refreshed inside the 1.5s autosave debounce lost the edit outright,
  # with nothing on screen to say so. Measured: 32KB sends, 63KB+ does not.
  test "an edit to an oversized deck is not silently dropped on unload" do
    # 20 languages across a real number of cards — what a translated Verto is,
    # and comfortably past the keepalive ceiling.
    locales = (I18n.available_locales.map(&:to_s) - [ "en" ]).first(19)
    big = Array.new(30) do |i|
      text = "Question #{i}: how safe do you feel here day to day, and how much do you feel part of this community?"
      { "type" => "yes_no", "cid" => "big#{i}", "text" => text, "options" => %w[Yes No],
        "i18n" => locales.index_with { |_l| { "text" => text, "options" => %w[Yes No] } } }
    end
    @survey.update!(cards: [ CARDS.first ] + big, locales: [ "en" ] + locales)

    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner

    payload_bytes = evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('[data-controller~="survey-editor"]')
        const c = window.Stimulus.getControllerForElementAndIdentifier(el, "survey-editor")
        return new Blob([JSON.stringify(c.serialize())]).size
      })()
    JS
    assert_operator payload_bytes, :>, 64 * 1024,
                    "precondition: this deck must exceed what a keepalive request can carry"

    execute_script(<<~JS)
      const el = document.querySelector("[data-survey-editor-target='vertoTitle']")
      el.textContent = "Saved Despite The Size"
      el.dispatchEvent(new Event("input", { bubbles: true }))
    JS

    # Flush the way a refresh does, before the 1.5s debounce could have fired.
    execute_script("window.dispatchEvent(new Event('pagehide'))")

    Timeout.timeout(10) do
      sleep 0.25 until @survey.reload.title == "Saved Despite The Size"
    end
    assert_equal "Saved Despite The Size", @survey.reload.title
  end

  test "a live Verto refuses structural edits in the editor" do
    # Answers are keyed by card index, so editing a deck that already has
    # responses silently misaligns what is stored. The server enforces it; this
    # checks the editor tells the creator rather than failing silently.
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answered: true,
                              answers: { "1" => { "type" => "yes_no", "value" => "Yes" } })

    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner

    assert @survey.reload.editing_locked?, "precondition: the Verto should be locked"
    assert_no_selector "[data-survey-editor-target='vertoTitle'][contenteditable='true']"
  end
end
