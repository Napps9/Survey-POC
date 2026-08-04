require "application_system_test_case"

# The editor's ⌘Z stack, which had no automated coverage at all.
#
# It has to be a browser test: the stack lives entirely in the client, holds
# detached DOM nodes as its inverse operations, and is driven by a keydown
# listener. Nothing about it is observable from a request test.
#
# The case that matters most is the ASYMMETRY one. Before this, adding a card
# pushed nothing onto the stack, so ⌘Z after an add popped whatever delete or
# reorder happened before it and silently undid *that* — the creator's card
# stayed, and something they'd finished with came back. A stack that undoes the
# wrong action is worse than one that does nothing, so that test is the point
# of this file rather than an extra.
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
    page.driver.browser.keyboard.type([ :Meta, "z" ])
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

    # Adding a card leaves focus in a text field, where ⌘Z belongs to the
    # browser by design. The creator's real gesture is to click away first, so
    # do the same — otherwise this asserts the skip rule, not the stack.
    evaluate_script("(() => { document.activeElement?.blur?.(); return true })()")
    press_undo

    # The added card goes; the earlier delete stays undone.
    assert_selector "[data-survey-editor-target='card']", count: before.size, wait: 5
    assert_no_selector "[data-card-cid='c2']"
    assert_equal before, card_texts.compact,
                 "undo popped the earlier delete instead of the card just added"
  end

  test "the undo button drives the same stack and tracks its depth" do
    open_editor

    # Nothing undoable yet: the button renders, disabled — visible so the
    # affordance (and the shortcut its tooltip teaches) is discoverable.
    assert_selector "[data-survey-editor-target='undoBtn'][disabled]"

    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"
    assert_no_selector "[data-survey-editor-target='undoBtn'][disabled]"

    # click_dom, not a pointer click — the button sits in the floating chrome
    # (same reason the add-question flow above is driven through the DOM). A
    # disabled button would swallow el.click() without firing the action, so
    # this also only passes through the enabled state asserted above.
    click_dom("[data-survey-editor-target='undoBtn']")

    assert_selector "[data-card-cid='c2']", wait: 5
    # The stack is empty again, and the button says so.
    assert_selector "[data-survey-editor-target='undoBtn'][disabled]"
  end

  test "undo does nothing on a live Verto" do
    # Structural edits are refused server-side once a Verto is live (423), so an
    # undo that mutated the DOM would show the creator a change that can never
    # save.
    #
    # The stack must be NON-EMPTY for this to prove anything: the review caught
    # the first version pressing ⌘Z with nothing on the stack, which passes
    # with the live-guard deleted. A live editor renders no delete buttons, so
    # the entry is planted directly — what matters is that a populated stack
    # is not popped.
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    open_editor
    # No button either: a live editor renders no undo affordance at all.
    assert_no_selector "[data-survey-editor-target='undoBtn']"
    execute_script(<<~JS)
      const app  = window.Stimulus || window.application
      const root = document.querySelector('[data-controller~="survey-editor"]')
      const c    = app.getControllerForElementAndIdentifier(root, "survey-editor")
      c._pushUndo(() => { window.__undoFired = true })
    JS
    before = card_texts

    press_undo

    assert_equal before, card_texts
    refute evaluate_script("!!window.__undoFired"),
           "the live guard must stop the stack being popped, not merely find it empty"
  end

  test "typing undo inside a text field is left to the browser" do
    # The handler skips inputs and contenteditables on purpose — the browser is
    # better at text undo than an operation stack. If it didn't, ⌘Z while
    # correcting a typo would delete a card.
    #
    # A structural edit FIRST, so the stack is non-empty — the review caught
    # the original pressing ⌘Z over an empty stack, which passes with the
    # text-field skip rule deleted.
    open_editor
    delete_card("c2")
    assert_no_selector "[data-card-cid='c2']"

    execute_script(<<~JS)
      document.querySelector("[data-survey-editor-target='card'] [contenteditable='true'], " +
                             "[data-survey-editor-target='card'] input[type='text']")?.focus()
    JS
    press_undo
    # ⌘Z in a text field must not pop a structural undo — c2 stays gone.
    assert_no_selector "[data-card-cid='c2']"

    # And blurring hands the same keystroke back to the stack.
    execute_script("document.activeElement?.blur?.()")
    press_undo
    assert_selector "[data-card-cid='c2']", wait: 5
  end
end
