require "application_system_test_case"

# The editor's undo/redo history.
#
# It has to be a browser test: the history lives entirely in the client, holds
# the deck's own DOM nodes and markup as its snapshots, and is driven by a
# keydown listener. Nothing about it is observable from a request test.
#
# Two shapes matter most. The ASYMMETRY one (BUG-014): when adding a card
# pushed nothing, ⌘Z after an add popped whatever delete or reorder happened
# before it and silently undid *that*. And its generalisation (BUG-042): a
# history that covers some edits and not others greys the button out after
# most changes and misattributes the next ⌘Z — so typing, options, types,
# switches and flows are all in it now, and each has a test here.
class EditorUndoTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Hello" },
    { "type" => "yes_no", "cid" => "c1", "text" => "First question?", "options" => %w[Yes No] },
    { "type" => "yes_no", "cid" => "c2", "text" => "Second question?", "options" => %w[Yes No] },
    { "type" => "yes_no", "cid" => "c3", "text" => "Third question?", "options" => %w[Yes No] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "un-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Un", email_address: "un-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Undo", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "First question?"
  end

  # ⌘Z through the CDP keyboard rather than send_keys: send_keys clicks the
  # element to focus it first (the trap BUG-009 was about), and the handler
  # deliberately ignores keys typed into an input or contenteditable, so a click
  # landing in the wrong place would make the test pass for the wrong reason.
  # The [modifier, char] tuple is the only form that works: Ferrum's
  # normalize_keys turns a bare modifier symbol into nil (it records it as a
  # held modifier rather than emitting a key), so keyboard.down(:Meta) raises.
  def press_undo
    press_keys([ :Meta, "z" ])
  end

  def press_redo
    press_keys([ :Control, "y" ])
  end

  EDITOR_JS = <<~JS.strip
    (() => {
      const app  = window.Stimulus || window.application
      const root = document.querySelector('[data-controller~="survey-editor"]')
      return app.getControllerForElementAndIdentifier(root, "survey-editor")
    })()
  JS

  # The stacks themselves, so a test waits on the commit that follows a
  # gesture (a macrotask) or a run of typing (a 700ms pause) rather than on
  # Ferrum's click wait happening to be long enough.
  def undo_depth
    evaluate_script("#{EDITOR_JS}._undoStack.length")
  end

  def redo_depth
    evaluate_script("#{EDITOR_JS}._redoStack.length")
  end

  def wait_for_undo_depth(n, seconds: 5)
    assert wait_until(timeout: seconds) { undo_depth == n },
           "undo depth stayed at #{undo_depth}, expected #{n}"
  end

  # Type at the END of a card's question title the way a creator does: focus,
  # caret after the last character, then real keystrokes — each one an input
  # event on the contenteditable, which is what the history groups.
  # press_keys rather than Element#send_keys: send_keys clicks the node's
  # centre first, which lands the caret mid-word.
  def type_into_title(cid, text)
    type_at_end("[data-card-cid='#{cid}'] .q-title", text)
  end

  def type_at_end(selector, text)
    el = find(selector)
    page.execute_script(<<~JS, el)
      const el = arguments[0]
      el.focus()
      const range = document.createRange()
      range.selectNodeContents(el)
      range.collapse(false)
      const sel = window.getSelection()
      sel.removeAllRanges()
      sel.addRange(range)
    JS
    press_keys(text)
  end

  def title_text(cid)
    find("[data-card-cid='#{cid}'] .q-title").text
  end

  def select_card(cid)
    find("[data-card-cid='#{cid}'] .card-num-pill").click
  end

  # evaluate_script, not execute_script — the latter discards its return value,
  # so a missing element would look identical to a successful click.
  def click_dom(selector, index: 0)
    ok = evaluate_script(<<~JS)
      (() => {
        const el = document.querySelectorAll(#{selector.to_json})[#{index}]
        if (!el) return false
        el.click()
        return true
      })()
    JS
    assert ok, "no element matched #{selector}"
  end

  def wait_for_js(expression, seconds: 5)
    Timeout.timeout(seconds) { sleep 0.1 until evaluate_script("(() => !!(#{expression}))()") }
  rescue Timeout::Error
    flunk "timed out waiting for: #{expression}"
  end

  def card_texts
    all("[data-survey-editor-target='card']").map { |c| c["data-card-cid"] }
  end

  def delete_card(cid)
    # Select via the card's number pill — it has no handler of its own, so the
    # click bubbles to type-panel#selectCard. A click at the wrap's centre can
    # land on the media "Add design" prompt and open the media modal instead,
    # whose backdrop then swallows the delete click.
    find("[data-card-cid='#{cid}'] .card-num-pill").click
    # The delete button asks for confirmation on the first press and acts on the
    # second — same two-step the creator gets.
    btn = find("[data-card-cid='#{cid}'] .card-delete-btn")
    btn.click
    btn.click
  end

  test "deleting a card and pressing undo brings it back" do
    open_editor
    assert_includes card_texts, "c2"

    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"

    press_undo
    assert_selector "[data-card-cid='c2']", wait: 5
    assert_equal %w[c1 c2 c3], card_texts.compact & %w[c1 c2 c3],
                 "the restored card should come back in its original position"
  end

  test "undo persists — the restored card survives a reload" do
    # ⌘Z calls markDirty like any other edit, so the restore has to reach the
    # server. If it only repaired the DOM the card would vanish again on reload.
    open_editor
    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"

    Timeout.timeout(10) { sleep 0.25 until @survey.reload.cards.none? { |c| c["cid"] == "c2" } }

    press_undo
    assert_selector "[data-card-cid='c2']", wait: 5
    Timeout.timeout(10) { sleep 0.25 until @survey.reload.cards.any? { |c| c["cid"] == "c2" } }

    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='c2']"
  end

  # THE regression guard for the asymmetry.
  test "undo after adding a card removes that card, not the previous edit" do
    open_editor

    # An edit that must NOT be undone by the ⌘Z below.
    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"
    before = card_texts.compact

    # Add a card through the real path — "Add question" → "Start from blank" →
    # pick a type → add. Blank rendering is server-side (render_card), so no
    # Claude call is involved.
    #
    # Clicked through the DOM rather than by coordinate: the feed's insert CTA
    # sits under the sticky editor chrome, so a pointer click lands on the
    # chrome instead. These are still real click events on the real buttons, so
    # every Stimulus action in the chain fires — what's skipped is only the
    # geometry, which is not what this test is about.
    # Selected by action, not by class: `.aq-insert-btn` is also worn by the
    # "Add consent gate" CTA, which sits earlier in the DOM — so the obvious
    # selector adds a consent gate instead of opening this modal.
    click_dom("[data-action*='add-question#open']")
    click_dom("[data-action*='add-question#chooseBlank']")
    click_dom(".aq-type-tile[data-type='yes_no']")

    # selectType advances on a 120ms timer, and "Add to survey" refuses a card
    # with no question text. Both waited on and driven through the DOM: the
    # modal's steps don't satisfy Capybara's visibility filter headless.
    wait_for_js("!document.querySelector(\"[data-add-question-target='stepDetails']\").hidden")
    evaluate_script(<<~JS)
      (() => {
        const f = document.querySelector("[data-add-question-target='questionText']")
        f.value = "Added in the browser?"
        f.dispatchEvent(new Event("input", { bubbles: true }))
        return true
      })()
    JS
    click_dom("[data-action*='add-question#addToSurvey']")

    assert_selector "[data-survey-editor-target='card']", count: before.size + 1, wait: 10

    # Adding a card leaves focus in the modal's own question input, which is
    # outside the deck and keeps the browser's undo. The creator's real
    # gesture is to click away first, so do the same.
    evaluate_script("(() => { document.activeElement?.blur?.(); return true })()")
    wait_for_undo_depth 2
    press_undo

    # The added card goes; the earlier delete stays undone.
    assert_selector "[data-survey-editor-target='card']", count: before.size, wait: 5
    assert_no_selector "[data-card-cid='c2']"
    assert_equal before, card_texts.compact,
                 "undo popped the earlier delete instead of the card just added"
  end

  test "the undo and redo buttons drive the same stacks and track their depth" do
    open_editor

    # Nothing undoable yet: both buttons render, disabled — visible so the
    # affordance (and the shortcuts their tooltips teach) is discoverable.
    assert_selector "[data-survey-editor-target='undoBtn'][disabled]"
    assert_selector "[data-survey-editor-target='redoBtn'][disabled]"

    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"
    wait_for_undo_depth 1
    assert_no_selector "[data-survey-editor-target='undoBtn'][disabled]"
    assert_selector "[data-survey-editor-target='redoBtn'][disabled]"

    # click_dom, not a pointer click — the buttons sit in the floating chrome
    # (same reason the add-question flow above is driven through the DOM). A
    # disabled button would swallow el.click() without firing the action, so
    # this also only passes through the enabled states asserted above.
    click_dom("[data-survey-editor-target='undoBtn']")

    assert_selector "[data-card-cid='c2']", wait: 5
    # The undone delete moved across: undo empty, redo holding it.
    assert_selector "[data-survey-editor-target='undoBtn'][disabled]"
    assert_no_selector "[data-survey-editor-target='redoBtn'][disabled]"

    click_dom("[data-survey-editor-target='redoBtn']")
    assert_no_selector "[data-card-cid='c2']", wait: 5
    assert_no_selector "[data-survey-editor-target='undoBtn'][disabled]"
    assert_selector "[data-survey-editor-target='redoBtn'][disabled]"
  end

  test "undo does nothing on a live Verto" do
    # Structural edits are refused server-side once a Verto is live (423), so an
    # undo that mutated the DOM would show the creator a change that can never
    # save.
    #
    # The stack must be NON-EMPTY for this to prove anything: the review caught
    # the first version pressing ⌘Z with nothing on the stack, which passes
    # with the live-guard deleted. A live editor records nothing, so an entry
    # is planted directly and the restore stubbed to a flag — what matters is
    # that a populated stack is not popped.
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    open_editor
    # No buttons either: a live editor renders no undo affordance at all.
    assert_no_selector "[data-survey-editor-target='undoBtn']"
    assert_no_selector "[data-survey-editor-target='redoBtn']"
    execute_script(<<~JS)
      const c    = #{EDITOR_JS}
      const side = { order: [], records: [], flows: null, title: null }
      c._undoStack.push({ before: side, after: side })
      c._applySnapshotSide = () => { window.__undoFired = true }
    JS
    before = card_texts

    press_undo

    assert_equal before, card_texts
    refute evaluate_script("!!window.__undoFired"),
           "the live guard must stop the stack being popped, not merely find it empty"
    assert_equal 1, undo_depth
  end

  test "⌘Z inside a card's text field uses the editor's history" do
    # The old stack handed the keystroke to the browser inside any text field,
    # so ⌘Z while correcting a typo could not touch the deck — and neither
    # could it undo the typo once the browser's own history had moved on. The
    # history owns the deck's text now, so a ⌘Z in a card's field undoes the
    # last deck change, whatever kind it was: here, the delete.
    open_editor
    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"
    wait_for_undo_depth 1

    execute_script(<<~JS)
      document.querySelector("[data-survey-editor-target='card'] [contenteditable='true']")?.focus()
    JS
    press_undo
    assert_selector "[data-card-cid='c2']", wait: 5
  end

  test "⌘Z in the consent gate is left to the browser" do
    # The gate cards save through update_settings, not the deck autosave, so
    # they are outside the history by design — and a ⌘Z typed into one must
    # not reach past it and undo a deck edit the creator can't see from there.
    @survey.update!(consent_text: "Please agree before you start.")
    open_editor
    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"
    wait_for_undo_depth 1

    execute_script("document.querySelector(\"[data-gate-cards-target='consentBody']\")?.focus()")
    press_undo
    # Proving nothing happens is the one thing a fixed wait is for.
    sleep 0.5
    assert_no_selector "[data-card-cid='c2']"
    assert_equal 1, undo_depth
  end

  # ── Every kind of edit, not just the structural ones ─────────────────────

  test "typing in a question then undo restores the text, and redo re-applies it" do
    open_editor
    type_into_title("c1", " Really?")
    assert_equal "First question? Really?", title_text("c1")
    wait_for_undo_depth 1

    press_undo
    assert_equal "First question?", title_text("c1")
    assert_equal 0, undo_depth
    assert_equal 1, redo_depth

    press_redo
    assert_equal "First question? Really?", title_text("c1")
    assert_equal 1, undo_depth
    assert_equal 0, redo_depth
  end

  test "a run of typing is one entry and a pause starts the next" do
    open_editor
    type_into_title("c1", " one two")
    wait_for_undo_depth 1
    # The caret is still in the title; typing on after the pause is a new run.
    press_keys(" three")
    wait_for_undo_depth 2

    press_undo
    assert_equal "First question? one two", title_text("c1")
    press_undo
    assert_equal "First question?", title_text("c1")
  end

  test "typing then undo persists — the restored text reaches the server" do
    open_editor
    type_into_title("c1", " Really?")
    wait_for_undo_depth 1
    assert wait_until(timeout: 10) { c1_text_on_server == "First question? Really?" },
           "the typed text never autosaved"

    press_undo
    assert_equal "First question?", title_text("c1")
    assert wait_until(timeout: 10) { c1_text_on_server == "First question?" },
           "the undo repaired the DOM but never reached the server"
  end

  test "deleting an option then undo brings it back in place" do
    @survey.update!(cards: CARDS + [ { "type" => "multiple_choice", "cid" => "c4", "text" => "Pick one",
                                       "options" => %w[Red Green Blue Gold] } ])
    open_editor
    assert_equal %w[Red Green Blue Gold], option_labels("c4")

    click_dom("[data-card-cid='c4'] .pick-item-delete", index: 1)
    assert_equal %w[Red Blue Gold], option_labels("c4")
    wait_for_undo_depth 1

    press_undo
    assert_equal %w[Red Green Blue Gold], option_labels("c4")
    press_redo
    assert_equal %w[Red Blue Gold], option_labels("c4")
  end

  test "toggling Required then undo puts the switch back" do
    open_editor
    select_card("c1")
    assert_selector "[data-card-cid='c1'][data-card-required='false'], [data-card-cid='c1']:not([data-card-required])"
    click_dom("[data-survey-editor-target='panelRequired']")
    assert_selector "[data-card-cid='c1'][data-card-required='true']"
    wait_for_undo_depth 1

    press_undo
    assert_no_selector "[data-card-cid='c1'][data-card-required='true']"
    # The panel's switch follows the card it points at.
    refute evaluate_script("document.querySelector(\"[data-survey-editor-target='panelRequired']\").checked")
  end

  test "changing the answer type then undo restores the previous type and its options" do
    open_editor
    select_card("c1")
    # The panel's own two-step: pick a tile, then Apply — clicked through the
    # DOM, since a tile the compatibility row hides is still a bound button.
    click_dom(".type-opt[data-type='multiple_choice']")
    click_dom("[data-action*='type-panel#applyType']")
    assert_selector "[data-card-cid='c1'][data-card-type='multiple_choice']"
    wait_for_undo_depth 1

    press_undo
    assert_selector "[data-card-cid='c1'][data-card-type='yes_no']"
    assert_equal %w[Yes No], evaluate_script("#{EDITOR_JS}.serialize().cards[1].options")
    # The panel re-read the card: the visible highlighted tile is what the
    # card is now. (A tile outside the card's compatibility list is hidden
    # before its class is touched, so only the VISIBLE one says anything.)
    assert_equal "yes_no", find(".type-opt.active")["data-type"]
  end

  test "renaming the Verto and its theme then undo restores each in turn" do
    # The two chrome spans save through serialize() like a card does, and
    # ⌘Z pressed inside either belongs to the history, not the browser.
    open_editor
    type_at_end("[data-survey-editor-target='vertoTitle']", " Two")
    wait_for_undo_depth 1
    type_at_end("[data-survey-editor-target='vertoTheme']", " Deluxe")
    wait_for_undo_depth 2
    assert_equal "Undo Two", find("[data-survey-editor-target='vertoTitle']").text
    assert_equal "Safety Deluxe", find("[data-survey-editor-target='vertoTheme']").text

    press_undo
    assert_equal "Safety", find("[data-survey-editor-target='vertoTheme']").text
    assert_equal "Undo Two", find("[data-survey-editor-target='vertoTitle']").text
    press_undo
    assert_equal "Undo", find("[data-survey-editor-target='vertoTitle']").text
    assert_equal %w[Undo Safety], evaluate_script("[#{EDITOR_JS}.titleValue, #{EDITOR_JS}.themeValue]")
    assert wait_until(timeout: 10) { @survey.reload.title == "Undo" && @survey.theme == "Safety" },
           "the restored name/theme never reached the server"
  end

  test "renaming a flow then undo restores the name" do
    # The flows panel only renders with the logic feature on.
    @survey.update!(logic: true,
                    cards: CARDS + [ { "type" => "open_ended", "cid" => "c_f1", "text" => "In the flow?", "flow_id" => "f_a" } ],
                    flows: [ { "id" => "f_a", "name" => "Original", "color" => "#8B85FF" } ])
    open_editor
    # The header pill renders its name in small caps, so match by regexp.
    assert_selector ".flow-header-name", text: /original/i

    # The flows panel's own name field, driven the way its listener expects:
    # a change event with the new value in place.
    execute_script(<<~JS)
      const input = document.querySelector("[data-flow-id='f_a'] .flow-name-input")
      input.value = "Renamed"
      input.dispatchEvent(new Event("change", { bubbles: true }))
    JS
    assert_selector ".flow-header-name", text: /renamed/i
    wait_for_undo_depth 1

    press_undo
    assert_selector ".flow-header-name", text: /original/i
    assert_equal "Original", evaluate_script("#{EDITOR_JS}.flowsList()[0].name")
  end

  test "an AI-optimise replace then undo brings the old card back, same element" do
    # Driven without Claude: the client's own _replaceCard with html from
    # render_card for an edited copy of the card, which is exactly what an
    # optimise response hands it.
    open_editor
    wait_for_js(<<~JS)
      (() => {
        if (window.__replaced !== undefined) return window.__replaced
        window.__replaced = false
        const c    = #{EDITOR_JS}
        const card = c.cardTargets.find(el => el.dataset.cardCid === "c2")
        const idx  = c.cardTargets.indexOf(card)
        const json = { ...c.serialize().cards[idx], text: "Second question, optimised?" }
        window.__cardBefore = card
        fetch(#{render_survey_card_path(@survey).to_json}, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Accept": "application/json",
                     "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
          body: JSON.stringify(json)
        }).then(r => r.json()).then(res => { c._replaceCard(card, res.html, json); window.__replaced = true })
        return false
      })()
    JS
    assert_equal "Second question, optimised?", title_text("c2")
    wait_for_undo_depth 1

    press_undo
    assert_equal "Second question?", title_text("c2")
    assert evaluate_script("window.__cardBefore === document.querySelector(\"[data-card-cid='c2']\")"),
           "the card should be morphed in place, not swapped for a new element"
  end

  test "an edit under a translation tab undoes that language only" do
    @survey.update!(locales: %w[en fr],
                    cards: CARDS.map { |c| c["cid"] == "c1" ? c.merge("i18n" => { "fr" => { "text" => "Première question ?", "options" => %w[Oui Non] } }) : c })
    open_editor
    click_dom("[data-survey-editor-target='tab'][data-locale='fr']")
    assert_equal "Première question ?", title_text("c1")

    type_into_title("c1", " Vraiment ?")
    assert_equal "Première question ? Vraiment ?", title_text("c1")
    wait_for_undo_depth 1

    press_undo
    assert_equal "Première question ?", title_text("c1")

    click_dom("[data-survey-editor-target='tab'][data-locale='en']")
    assert_equal "First question?", title_text("c1")
    assert wait_until(timeout: 10) { c1_on_server.dig("i18n", "fr", "text") == "Première question ?" },
           "the French text on the server is #{c1_on_server.dig('i18n', 'fr', 'text').inspect}"
    assert_equal "First question?", c1_on_server["text"]
  end

  private

  def c1_on_server
    @survey.reload.cards.find { |c| c["cid"] == "c1" } || {}
  end

  def c1_text_on_server
    c1_on_server["text"]
  end

  def option_labels(cid)
    all("[data-card-cid='#{cid}'] .pick-item .pick-text").map(&:text)
  end
end
