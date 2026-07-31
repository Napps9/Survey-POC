require "application_system_test_case"

# BUG-017. The framework provenance a generated card carries — which
# Awareness/Intention/Agency competency it sits under, its enabling condition,
# and the plain-language outcome — is what the editor's "Why this card?" panel
# reads. The DOM carried all three as data-* attributes and `serialize()` never
# read them back, so the first autosave stripped them from every card in the
# deck and the panel went permanently empty.
#
# Same shape as BUG-015 and, like it, only observable through a real editor
# round trip: the sanitiser preserves these fields perfectly, and the server
# never sees them because the client stops sending them.
class FrameworkTagsTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "fw-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Fw", email_address: "fw-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @competency = Framework.competencies.first.first
    @condition  = Framework.conditions.first.first

    @survey = @org.surveys.create!(
      title: "Framework", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "yes_no", "cid" => "tagged", "text" => "Do you feel safe here?",
          "options" => %w[Yes No], "competency" => @competency,
          "condition" => @condition, "outcome" => "Shows who acts" },
        { "type" => "yes_no", "cid" => "other", "text" => "Second question?",
          "options" => %w[Yes No] }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Do you feel safe here?"
  end

  def tagged_card
    @survey.reload.cards.find { |c| c["cid"] == "tagged" }
  end

  test "the framework tags reach the editor DOM" do
    open_editor
    assert_selector "[data-card-cid='tagged'][data-card-competency='#{@competency}']"
    assert_selector "[data-card-cid='tagged'][data-card-condition='#{@condition}']"
  end

  # The regression guard: the edit is to a DIFFERENT card, because serialize()
  # rebuilds the whole deck on every save — so a gap in it destroys provenance
  # on cards the creator never opened.
  test "editing another card does not strip the framework tags" do
    open_editor

    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='other'] .q-title")
      q.textContent = "Second question, reworded?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.cards.any? { |c| c["text"].to_s.include?("reworded") }
    end

    card = tagged_card
    assert_equal @competency, card["competency"], "the competency was lost on autosave"
    assert_equal @condition,  card["condition"],  "the enabling condition was lost on autosave"
    assert_equal "Shows who acts", card["outcome"], "the outcome was lost on autosave"
  end

  test "editing the tagged card itself keeps its tags" do
    open_editor

    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='tagged'] .q-title")
      q.textContent = "Do you feel safe around here?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    Timeout.timeout(15) do
      sleep 0.25 until tagged_card["text"].to_s.include?("around here")
    end

    assert_equal @competency, tagged_card["competency"]
  end

  # The other half of carrying a field from the client: the server now receives
  # it from a PATCH, so it has to stop trusting it. SurveyGenerator allowlists
  # these on generation, but that path is not this one.
  test "the server drops a competency the framework does not define" do
    payload = [ { "type" => "yes_no", "text" => "Q?", "options" => %w[Yes No],
                  "competency" => "invented", "condition" => "also-invented",
                  "outcome" => "y" * 5_000 } ]
    card = Survey.sanitize_cards_images!(payload, warnings: []).first

    assert_nil card["competency"]
    assert_nil card["condition"]
    assert_equal Survey::MAX_OUTCOME_LENGTH, card["outcome"].length,
                 "outcome is free text, so it is capped rather than allowlisted"
  end
end
