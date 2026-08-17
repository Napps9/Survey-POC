require "application_system_test_case"

# Drag-and-drop reorder (2.9): native HTML5 drag events driving the SAME
# invariants moveCardUp/moveCardDown already enforce one step at a time
# (survey_editor_controller.js#_legalGapsFor generalises _reorderNeighbor's
# walk instead of reimplementing it) — a flow member stays inside its own
# flow, a spine card hops a whole flow run as one unit, nothing but a
# consent gate lands ahead of the welcome card.
#
# Capybara/Cuprite's own drag_to is pure CDP mouse simulation (mouse down,
# move, up — see cuprite/browser.rb#drag) and does not reliably make Chrome
# recognise a native HTML5 drag gesture even with many intermediate steps
# (verified: it never fired a single dragstart here). So each test dispatches
# real DragEvents directly instead — this exercises exactly the same
# listeners a genuine drag would, just without depending on Chrome's gesture
# heuristics to get there.
class CardDragReorderTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "cid" => "c_welcome", "title" => "hi" },
    { "type" => "yes_no", "cid" => "c_spine1", "text" => "Spine 1?", "options" => %w[Yes No] },
    { "type" => "open_ended", "cid" => "c_flow1", "text" => "Flow 1?", "flow_id" => "f_a" },
    { "type" => "open_ended", "cid" => "c_flow2", "text" => "Flow 2?", "flow_id" => "f_a" },
    { "type" => "yes_no", "cid" => "c_spine2", "text" => "Spine 2?", "options" => %w[Yes No] }
  ].freeze
  FLOWS = [ { "id" => "f_a", "name" => "A", "color" => "#8B85FF", "exit" => { "end" => "default" } } ].freeze

  def setup
    super
    @user = User.create!(name: "U", email_address: "drag-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org = Organisation.create!(name: "O", slug: "drag-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "Drag", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: CARDS, flows: FLOWS)
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Spine 1?"
  end

  # Fires the real four-event sequence a native drag produces
  # (dragstart on the grip, dragover + drop on the target, dragend back on
  # the grip) with a genuine DataTransfer — see the class comment for why
  # this replaces Capybara's own drag_to here.
  def simulate_drag(grip_selector, target_selector)
    evaluate_script(<<~JS)
      (() => {
        const source = document.querySelector(#{grip_selector.to_json})
        const target = document.querySelector(#{target_selector.to_json})
        const dt = new DataTransfer()
        const fire = (type, el) => el.dispatchEvent(
          new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt })
        )
        fire("dragstart", source)
        fire("dragover", target)
        fire("drop", target)
        fire("dragend", source)
      })()
    JS
  end

  def grip_selector(cid) = "[data-card-cid='#{cid}'] [data-role='grip']"
  def card_selector(cid) = "[data-card-cid='#{cid}']"

  def cids
    @survey.reload.cards.map { |c| c["cid"] }
  end

  def wait_for_order(*expected)
    Timeout.timeout(10) { sleep 0.2 until cids == expected }
  end

  test "dragging a spine card hops the whole flow run and restamps card numbers" do
    open_editor
    simulate_drag(grip_selector("c_spine1"), card_selector("c_spine2"))

    wait_for_order("c_welcome", "c_flow1", "c_flow2", "c_spine1", "c_spine2")
    # Card 1 is welcome; "Spine 1?" hopped the whole flow run to become 4th.
    assert_equal "4", find("[data-card-cid='c_spine1'] [data-role='card-number']").text
    assert_equal "3", find("[data-card-cid='c_flow2'] [data-role='card-number']").text
  end

  test "the undo button restores the pre-drag position" do
    open_editor
    simulate_drag(grip_selector("c_spine1"), card_selector("c_spine2"))
    wait_for_order("c_welcome", "c_flow1", "c_flow2", "c_spine1", "c_spine2")

    find(".editor-undo-btn").click
    wait_for_order("c_welcome", "c_spine1", "c_flow1", "c_flow2", "c_spine2")
  end

  test "a flow member cannot be dragged out ahead of the flow" do
    open_editor
    original = cids

    # c_flow1 may only reorder WITHIN f_a (swap with c_flow2) — dragging it
    # onto a spine card outside the flow must find no legal gap and no-op.
    simulate_drag(grip_selector("c_flow1"), card_selector("c_spine1"))
    sleep 0.5 # nothing SHOULD happen; give a real move a chance to land first
    assert_equal original, cids, "a flow member escaped its own flow"
  end

  test "a flow member can still swap with its other flow member" do
    open_editor
    simulate_drag(grip_selector("c_flow1"), card_selector("c_flow2"))
    wait_for_order("c_welcome", "c_spine1", "c_flow2", "c_flow1", "c_spine2")
  end

  test "nothing but a consent gate may be dragged ahead of the welcome card" do
    open_editor
    original = cids

    simulate_drag(grip_selector("c_spine1"), ".survey-card-wrap[data-card-type='welcome_card']")
    sleep 0.5
    assert_equal original, cids, "a question jumped ahead of the pinned welcome card"
  end
end
