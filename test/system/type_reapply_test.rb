require "application_system_test_case"

# BUG-021. Re-applying a card's answer type rebuilt it from
# `data-card-options` / `data-card-pages` — attributes the server writes once at
# page render and nothing ever updates. So the rebuild used the labels the card
# had when the page loaded, discarding every option edit made since, and the
# autosave that follows a type change then persisted the revert.
#
# The DOM is the editor's source of truth, which is exactly why a snapshot taken
# of it at load time goes stale the moment anyone types.
class TypeReapplyTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tr-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tr", email_address: "tr-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Reapply", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "multiple_choice", "cid" => "c1", "text" => "How old are you?",
          "options" => [ "Option A", "Option B", "Option C" ] },
        { "type" => "range", "cid" => "r1", "text" => "How often?",
          "options" => [ "Never", "Rarely", "Sometimes", "Often", "Always" ] }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How old are you?"
  end

  # Retype the option labels the way a creator does — in the contenteditable
  # nodes serialize() reads.
  def relabel_options(labels, cid: "c1", selector: ".pick-text")
    execute_script(<<~JS)
      const card = document.querySelector("[data-card-cid='#{cid}']")
      const els  = card.querySelectorAll(#{selector.to_json})
      const next = #{labels.to_json}
      els.forEach((el, i) => {
        if (next[i] === undefined) return
        el.textContent = next[i]
        el.dispatchEvent(new Event("input", { bubbles: true }))
      })
    JS
  end

  # applyType, not _applyToCard: the real gesture goes through the public entry
  # point, which is what dispatches "changed" and gets the editor to mark dirty.
  # Calling the private rebuild directly skipped the autosave entirely, which
  # made the persistence test below pass whether or not the bug was present.
  def reapply_type(type, cid: "c1")
    execute_script(<<~JS)
      const app  = window.Stimulus || window.application
      const root = document.querySelector('[data-controller~="type-panel"]')
      const tp   = app.getControllerForElementAndIdentifier(root, "type-panel")
      const card = document.querySelector("[data-card-cid='#{cid}']")
      tp.activeCardEl = card
      tp.pendingType  = #{type.to_json}
      tp.applyType()
    JS
  end

  def stored_options(cid = "c1")
    @survey.reload.cards.find { |c| c["cid"] == cid }["options"]
  end

  def on_screen_options(cid: "c1", selector: ".pick-text")
    evaluate_script(<<~JS)
      (() => Array.from(document.querySelectorAll("[data-card-cid='#{cid}'] #{selector}"))
                  .map(el => el.textContent.trim()))()
    JS
  end

  test "the option labels a creator typed survive re-applying the same type" do
    open_editor
    relabel_options([ "Under 18", "18-24", "25-34" ])

    Timeout.timeout(15) { sleep 0.25 until stored_options == [ "Under 18", "18-24", "25-34" ] }

    reapply_type("multiple_choice")

    assert_equal [ "Under 18", "18-24", "25-34" ], on_screen_options,
                 "re-applying the type rebuilt the card from the render-time snapshot, " \
                 "throwing away the labels the creator typed"
  end

  test "and the revert is not then autosaved over the real labels" do
    open_editor
    relabel_options([ "Under 18", "18-24", "25-34" ])
    Timeout.timeout(15) { sleep 0.25 until stored_options == [ "Under 18", "18-24", "25-34" ] }

    reapply_type("multiple_choice")

    # A type change marks the editor dirty, so the rebuild reaches the server.
    sleep 3
    assert_equal [ "Under 18", "18-24", "25-34" ], stored_options,
                 "the autosave that follows a type change persisted the reverted labels"
  end

  # The behaviour the snapshot exists for, which must keep working: switching to
  # a type with no options and back restores what was there.
  test "switching away to a type with no options and back restores the labels" do
    open_editor
    relabel_options([ "Under 18", "18-24", "25-34" ])
    Timeout.timeout(15) { sleep 0.25 until stored_options == [ "Under 18", "18-24", "25-34" ] }

    reapply_type("open_ended")
    reapply_type("multiple_choice")

    assert_equal [ "Under 18", "18-24", "25-34" ], on_screen_options,
                 "the switch-away-and-back memory should hold the edited labels, not the " \
                 "ones the server rendered"
  end

  # A RANGE label is a positional stop, not a list entry — a blank one means
  # "unnamed stop", and every label after it still belongs to its own stop.
  # _liveOptions used to filter blanks for every type, so re-applying the type
  # on a range card with a blanked label handed the rebuild 4 labels, and the
  # upsampler re-spread them across 5 stops — sliding the creator's remaining
  # words onto the wrong positions and autosaving the shuffle.
  test "a blanked range label does not shift the other stops on re-apply" do
    open_editor
    assert_text "How often?"

    # Blank the second stop, the way a creator clears a label they don't want.
    relabel_options([ "Never", "" ], cid: "r1", selector: ".slider-label-text")

    reapply_type("range", cid: "r1")

    labels = on_screen_options(cid: "r1", selector: ".slider-label-text")
    assert_equal 5, labels.size, "a range card must keep all #{5} stops"
    assert_equal "Sometimes", labels[2],
                 "blanking stop 2 slid the later labels onto earlier stops — " \
                 "range labels are positional and must not be compacted"
    assert_equal "Always", labels[4]

    # And the save that follows keeps the alignment: the server names the blank
    # stop from the default scale but never moves a label the creator kept.
    sleep 3
    stored = stored_options("r1")
    assert_equal 5, stored.size
    assert_equal "Sometimes", stored[2],
                 "the autosave after the re-apply persisted the re-spread labels"
    assert_equal "Always", stored[4]
  end
end
