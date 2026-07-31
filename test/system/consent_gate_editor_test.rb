require "application_system_test_case"

# The multi-page consent gate, driven through the editor.
#
# This is the test whose absence let a broken feature ship looking finished.
# `test/integration/consent_gate_card_test.rb` is 231 green lines, but it calls
# `Survey.sanitize_cards_images!` with pages already supplied and renders from
# cards seeded via `create!` — it never makes a round trip through the editor.
# The editor's `serialize()` gated page serialisation on `type === "scenario"`,
# so a consent gate autosaved with no pages at all, the sanitiser rewrote them
# to `[]`, and the gate went on blocking respondents while showing a blank
# screen and recording no consent snapshot.
#
# `serialize()` rebuilds every card from live DOM on every save, so the only
# thing that can catch that class of defect is a browser.
class ConsentGateEditorTest < ApplicationSystemTestCase
  PAGES = [
    { "id" => "pg_a", "text" => "This study asks about how safe you feel locally." },
    { "id" => "pg_b", "text" => "Your answers are anonymous and you can stop at any time." }
  ].freeze

  CARDS = [
    { "type" => "welcome_card", "title" => "Hello" },
    { "type" => "consent_gate", "cid" => "cg1", "text" => "Before you start", "pages" => PAGES },
    { "type" => "yes_no", "cid" => "q1", "text" => "Do you feel safe here?", "options" => %w[Yes No] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "cg-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Cg", email_address: "cg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Consent", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Do you feel safe here?"
  end

  def consent_card
    @survey.reload.cards.find { |c| c["type"] == "consent_gate" }
  end

  def page_texts
    Array(consent_card["pages"]).map { |p| p["text"] }
  end

  test "the consent gate renders its pages in the editor" do
    open_editor
    assert_text "This study asks about how safe you feel locally."
    assert_text "Your answers are anonymous and you can stop at any time."
  end

  # THE regression guard. The consent copy is not what is being edited here —
  # an unrelated card is — and that is the point: serialize() rebuilds the whole
  # deck on every save, so a gap in it destroys content the creator never
  # touched.
  test "editing an unrelated card does not wipe the consent pages" do
    open_editor

    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='q1'] .q-title")
      q.textContent = "Do you feel safe in this area?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    # Wait for the edit itself to land, so the assertion below is made against a
    # save that definitely happened rather than one that never fired.
    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.cards.any? { |c| c["text"].to_s.include?("in this area") }
    end

    assert_equal PAGES.map { |p| p["text"] }, page_texts,
                 "an autosave triggered by an unrelated edit dropped the consent pages"
  end

  test "the consent snapshot survives an autosave" do
    # pages -> consent_snapshot_text is what Response#consent_text_snapshot
    # records. Empty pages leave it nil, so the Verto keeps gating respondents
    # while storing no evidence of what they agreed to.
    open_editor
    assert @survey.reload.consent_snapshot_text.present?, "precondition"

    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='q1'] .q-title")
      q.textContent = "Safe around here?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.cards.any? { |c| c["text"].to_s.include?("Safe around here") }
    end

    assert @survey.reload.consent_snapshot_text.present?,
           "the consent snapshot — the record of what respondents agreed to — was lost on autosave"
  end

  test "editing a consent page persists that page" do
    open_editor

    execute_script(<<~JS)
      const el = document.querySelectorAll("[data-card-cid='cg1'] [data-scenario-target='pageText']")[0]
      el.textContent = "This study asks how safe you feel where you live."
      el.dispatchEvent(new Event("input", { bubbles: true }))
      el.blur()
    JS

    Timeout.timeout(15) do
      sleep 0.25 until page_texts.first.to_s.include?("where you live")
    end

    assert_equal 2, page_texts.size, "editing one page should not drop the other"
    assert_includes page_texts[1], "anonymous"
  end
end
