require "application_system_test_case"

# BUG-022 and BUG-023, both in the scenario/consent book editor.
#
# BUG-022 — `Survey::MAX_SCENARIO_PAGES` had no client-side counterpart, so
# "＋ Add page" kept adding. The sanitiser keeps only the first six, so a
# creator could write a seventh page, watch the editor say "Saved", and find it
# gone on reload with nothing having said why.
#
# BUG-023 — `addPage`/`deletePage` dispatch `scenario:changed`, and the editor
# root listened to `type-panel:changed` and `card-editor:changed` but not that.
# Adding a page usually survived by accident, because typing into the new page
# fires `input`, which the root does listen to. Deleting one had no such luck:
# the page vanished, nothing marked the editor dirty, no save was scheduled, and
# the page came back on reload.
class ScenarioPagesTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "sp-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Sp", email_address: "sp-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Pages", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "scenario", "cid" => "sc1", "text" => "What would you do?",
          "options" => [ "Speak up", "Say nothing" ],
          "pages" => (1..3).map { |i| { "id" => "pg#{i}", "text" => "Page #{i} of the story." } } }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Page 1 of the story."
  end

  def add_page
    execute_script(<<~JS)
      const app  = window.Stimulus || window.application
      const wrap = document.querySelector("[data-card-cid='sc1'] .book-wrap")
      app.getControllerForElementAndIdentifier(wrap, "scenario").addPage()
    JS
  end

  def delete_page
    execute_script(<<~JS)
      const app  = window.Stimulus || window.application
      const wrap = document.querySelector("[data-card-cid='sc1'] .book-wrap")
      app.getControllerForElementAndIdentifier(wrap, "scenario").deletePage()
    JS
  end

  # Narrative pages only — the last .book-page is the answer page.
  def narrative_page_count
    evaluate_script("document.querySelectorAll(\"[data-card-cid='sc1'] .book-page\").length").to_i - 1
  end

  def stored_pages
    Array(@survey.reload.cards.find { |c| c["cid"] == "sc1" }["pages"])
  end

  test "the editor refuses to add more pages than the server will keep" do
    open_editor
    assert_equal 3, narrative_page_count

    10.times { add_page }

    assert_equal Survey::MAX_SCENARIO_PAGES, narrative_page_count,
                 "the editor let the creator write pages the sanitiser will silently discard"
  end

  test "the add button is disabled at the cap" do
    open_editor
    (Survey::MAX_SCENARIO_PAGES - 3).times { add_page }

    assert_selector "[data-card-cid='sc1'] [data-scenario-target='addPageBtn'][disabled]",
                    wait: 3
  end

  test "deleting a page persists" do
    open_editor
    assert_equal 3, stored_pages.size

    delete_page
    assert_equal 2, narrative_page_count

    Timeout.timeout(15) { sleep 0.25 until stored_pages.size == 2 }
    assert_equal 2, stored_pages.size,
                 "deleting a page never marked the editor dirty, so the deletion was discarded"
  end

  test "adding a page persists without needing an unrelated edit" do
    open_editor
    add_page

    # serialize() drops pages with no text — an empty page is not content, and
    # that is deliberate. Write into it the way a creator would.
    execute_script(<<~JS)
      // addPage inserts after the page currently open, not at the end, so find
      // the blank one rather than assuming a position.
      const pages = Array.from(document.querySelectorAll("[data-card-cid='sc1'] [data-scenario-target='pageText']"))
      const el = pages.find(p => !p.textContent.trim())
      el.textContent = "A fourth page of the story."
      el.dispatchEvent(new Event("input", { bubbles: true }))
    JS

    Timeout.timeout(15) { sleep 0.25 until stored_pages.size == 4 }
    assert_includes stored_pages.map { |pg| pg["text"] }, "A fourth page of the story."
  end
end
