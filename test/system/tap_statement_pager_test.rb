require "application_system_test_case"

# Walking a tap card's deck in the EDITOR.
#
# A respondent moves the stack by answering — pick() and the drag both throw the
# top card off and surface the next. A creator never had that move. In the
# editor the response strip is entirely spoken for: the mark opens the 🎨
# popover (option-style#open stops propagation), the label is contenteditable
# and pick() bails on it by design, and the 🎨 and × are their own buttons. So
# `tap-stack#pick` had no click target left, the deck never advanced, and only
# ever the FIRST statement was the top card.
#
# Which meant every statement after the first was unreachable from the editor.
# Not merely awkward: unreadable (the cards below the top are drawn at opacity
# 0 past the third), unedittable, and out of reach of its own image and delete
# buttons — tap-stack#layout gives `pointer-events: auto` to the top card
# alone. A four-statement deck was a one-statement deck to whoever had to write
# it.
#
# The pager is the editor's way through. It moves the stack WITHOUT recording
# an answer, which is the whole difference between reviewing a deck and
# answering it — so these tests check both halves: that the statements can be
# reached, and that reaching them doesn't quietly fill the card in.
class TapStatementPagerTest < ApplicationSystemTestCase
  STATEMENTS = [ "Meetings drain me", "I get deep work done",
                 "Fridays are wasted", "I know what is expected" ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tsp-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tsp", email_address: "tsp-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Tap", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "React to these",
          "options" => STATEMENTS.dup }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    # visible: :all throughout — a stack draws everything past the third card at
    # opacity 0, and which cards those are is exactly what these tests move.
    assert_selector "[data-card-cid='t1'] .rotate-card", count: 4, visible: :all
  end

  # The statement a creator can actually work on. Deliberately read off
  # `pointer-events` rather than off the controller's `position`: that property
  # IS the reach — layout() hands it to the top card and takes it from every
  # other one, so it is what decides whether the ✕, the image button and the
  # caret belong to this statement or to no one.
  def reachable_statement
    evaluate_script(<<~JS)
      (() => {
        const cards = [...document.querySelectorAll("[data-card-cid='t1'] .rotate-card")]
        const top = cards.find((c) => c.style.pointerEvents === "auto")
        return top ? top.querySelector(".rotate-card-statement span").textContent.trim() : null
      })()
    JS
  end

  def pager_count
    find("[data-card-cid='t1'] .tap-nav-count").text.strip
  end

  # Retried rather than trusted, and deliberately so. A click on this card can
  # be lost to a layout move underneath it — that is how these tests first
  # failed, twice, under the full suite while passing alone. layout() sets the
  # reach synchronously inside the click handler, so a step that has landed has
  # already moved by the time the poll below looks; nothing changing for half a
  # second means the click never reached the button, not that it is still on
  # its way, and clicking again cannot double-step.
  def step(direction)
    was = reachable_statement
    button = "[data-card-cid='t1'] .tap-nav-btn[data-tap-stack-target='#{direction}Btn']"
    Timeout.timeout(15) do
      loop do
        find(button).click
        5.times do
          break if reachable_statement != was
          sleep 0.1
        end
        break if reachable_statement != was
      end
    end
  end

  def stored_card
    @survey.reload.cards.find { |c| c["cid"] == "t1" }
  end

  # Type into the statement currently on top, the way a creator does — the
  # editor listens for `input` on its root and schedules the autosave from
  # there, so a bare textContent assignment would change the screen and save
  # nothing.
  def rewrite_reachable_statement(text)
    ok = evaluate_script(<<~JS)
      (() => {
        const cards = [...document.querySelectorAll("[data-card-cid='t1'] .rotate-card")]
        const top = cards.find((c) => c.style.pointerEvents === "auto")
        if (!top) return false
        const span = top.querySelector(".rotate-card-statement span")
        span.textContent = #{text.to_json}
        span.dispatchEvent(new Event("input", { bubbles: true }))
        return true
      })()
    JS
    assert ok, "no reachable statement to type into"
  end

  test "the pager walks the deck, forwards and back" do
    open_editor

    assert_equal STATEMENTS[0], reachable_statement
    assert_equal "Statement 1 of 4", pager_count

    step("next")
    assert_equal STATEMENTS[1], reachable_statement
    assert_equal "Statement 2 of 4", pager_count

    step("next")
    assert_equal STATEMENTS[2], reachable_statement

    step("prev")
    assert_equal STATEMENTS[1], reachable_statement,
                 "the pager goes both ways — a creator who has stepped past a statement has to " \
                 "be able to come back to it"
    assert_equal "Statement 2 of 4", pager_count
  end

  # The point of the whole thing: the statements behind the first one can be
  # written, and what is written is saved against the right one.
  test "a statement reached with the pager can be edited and saves in its own slot" do
    open_editor
    step("next")
    step("next")

    rewrite_reachable_statement("Fridays are the best day")
    Timeout.timeout(15) { sleep 0.25 until stored_card["options"][2] == "Fridays are the best day" }

    assert_equal [ STATEMENTS[0], STATEMENTS[1], "Fridays are the best day", STATEMENTS[3] ],
                 stored_card["options"],
                 "the edit landed on the wrong statement — options are POSITIONAL, and every " \
                 "stored answer is keyed by that position"
  end

  # Stepping is not answering. If the pager went through pick(), walking a deck
  # to proof-read it would fill in a full set of answers on the creator's own
  # preview — and on the last statement it would tip the card into its
  # all-answered face, hiding the deck the creator came to edit.
  test "walking the deck records no answers and never reaches the answered face" do
    open_editor
    3.times { step("next") }

    assert_equal STATEMENTS[3], reachable_statement
    assert_no_selector "[data-card-cid='t1'] .rotate-wrap.is-complete"
    assert_equal "{}", evaluate_script(
      "document.querySelector(\"[data-card-cid='t1'] .rotate-wrap\").dataset.swipeResults || '{}'"
    ), "the pager recorded answers on the creator's behalf"
  end

  # Both ends have to say so. The stack looks identical whether or not there is
  # another statement behind the top card, so a dead chevron is the only thing
  # that tells a creator they have reached the end of the deck.
  test "the pager's ends are disabled" do
    open_editor
    prev = find("[data-card-cid='t1'] .tap-nav-btn[data-tap-stack-target='prevBtn']", visible: :all)
    nxt  = find("[data-card-cid='t1'] .tap-nav-btn[data-tap-stack-target='nextBtn']", visible: :all)

    assert prev.disabled?, "there is nothing before the first statement"
    assert_not nxt.disabled?

    3.times { step("next") }
    assert nxt.disabled?, "there is nothing after the last statement"
    assert_not prev.disabled?
  end

  # ＋ Add statement appends, then focuses the new statement's caret. Before the
  # pager existed it also reset the stack to the front, so on a deck of four or
  # more the caret was placed in a card three deep at opacity 0: the creator
  # typed a statement they could not see, into a card they could not reach.
  test "adding a statement lands on the statement it added" do
    open_editor
    find("[data-card-cid='t1'] .tap-add-btn").click

    assert_selector "[data-card-cid='t1'] .rotate-card", count: 5, visible: :all
    assert_equal "Statement 5 of 5", pager_count
    assert_equal "New statement", reachable_statement,
                 "the ＋ focused a statement the creator cannot see — everything typed goes into " \
                 "a card three deep in the stack at opacity 0"
  end

  # Deleting used to reset the stack to the front, so removing the third of four
  # meant paging forward twice to carry on where you were.
  test "deleting a statement holds the creator's place" do
    open_editor
    step("next")
    step("next")
    assert_equal STATEMENTS[2], reachable_statement

    evaluate_script(<<~JS)
      (() => {
        const cards = [...document.querySelectorAll("[data-card-cid='t1'] .rotate-card")]
        const top = cards.find((c) => c.style.pointerEvents === "auto")
        top.querySelector(".tap-card-delete").click()
      })()
    JS

    assert_selector "[data-card-cid='t1'] .rotate-card", count: 3, visible: :all
    assert_equal STATEMENTS[3], reachable_statement,
                 "deleting the third statement should leave the creator looking at whatever is " \
                 "third now, not send them back to the top of the deck"
    assert_equal "Statement 3 of 3", pager_count
  end
end
