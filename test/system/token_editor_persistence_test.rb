require "application_system_test_case"

# The two in-browser halves of "my token values keep disappearing":
#
# 1. The Tokenisation panel's own controls are full-page POST→redirect forms
#    sitting directly above the token inputs, and Turbo drives them — so the
#    pagehide/beforeunload flush never fired and an amount typed inside the
#    1.5s debounce was discarded by the re-render. The editor now completes
#    the pending save before letting any of its forms submit.
#
# 2. The per-answer award rows are server-rendered once, keyed by canonical
#    option label. Renaming an option orphaned its amounts: the next autosave
#    wrote `tokens` under the old label, the inputs read back 0, and grading
#    matched nothing. syncTokenRowsFor now rebuilds the rows as options
#    change, carrying amounts uid → label → position like branching does.
class TokenEditorPersistenceTest < ApplicationSystemTestCase
  TYPES = [ { "id" => "t1", "icon" => "⭐", "name" => "Stars" } ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tep-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tp", email_address: "tep-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Tokens", theme: "T", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      tokenisation_enabled: true, token_types: JSON.parse(TYPES.to_json),
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "multiple_choice", "cid" => "c1", "text" => "Pick one",
          "options" => [ "Option A", "Option B" ],
          "tokens" => { "Option A" => { "t1" => 2 } } }
      ])
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Pick one"
  end

  def stored_tokens
    @survey.reload.cards.find { |c| c["cid"] == "c1" }["tokens"]
  end

  test "an amount typed just before a settings form submits still lands" do
    open_editor

    # Type an amount for Option B, then submit the intro-picker form inside
    # the debounce window — the exact gesture that used to discard the value.
    execute_script(<<~JS)
      const card  = document.querySelector("[data-card-cid='c1']")
      const row   = card.querySelector('[data-token-mode-section="per_answer"] .token-award-row[data-canonical="Option B"]')
      const input = row.querySelector(".token-amount-input")
      input.value = 7
      input.dispatchEvent(new Event("input", { bubbles: true }))
      document.querySelector("#token-intro-cid").form.requestSubmit()
    JS

    # The editor must complete the PATCH before the form's POST→redirect→GET,
    # so the page the round trip renders already carries the amount. Waiting
    # on the DOM (not just the DB) is the point: a late PATCH could satisfy
    # the database while the re-rendered editor still showed 0 — the stale
    # page the NEXT autosave would then persist.
    Timeout.timeout(15) do
      sleep 0.25 until evaluate_script(<<~JS) == "7"
        document.querySelector("[data-card-cid='c1'] [data-token-mode-section='per_answer'] .token-award-row[data-canonical='Option B'] .token-amount-input")?.value
      JS
    end
    assert_equal 7, stored_tokens.dig("Option B", "t1")
    assert_equal 2, stored_tokens.dig("Option A", "t1"), "the untouched option keeps its amount"
  end

  test "renaming an option carries its token amounts to the new label" do
    open_editor

    execute_script(<<~JS)
      const el = document.querySelector("[data-card-cid='c1'] .pick-text")
      el.textContent = "Alpha"
      el.dispatchEvent(new Event("input", { bubbles: true }))
      el.dispatchEvent(new Event("focusout", { bubbles: true }))
    JS

    Timeout.timeout(10) { sleep 0.25 until (stored_tokens || {}).key?("Alpha") }
    assert_equal({ "Alpha" => { "t1" => 2 } }, stored_tokens,
                 "the amounts must follow the rename instead of staying keyed " \
                 "under a label the card no longer has")
  end
end
