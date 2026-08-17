require "application_system_test_case"

# CardSubjectExtractor's photographable-subject stamp (card["subject"]) is
# invisible in the editor — nothing displays or edits it — so it only
# survives a real autosave round trip if the DOM carries it AND serialize()
# reads it back. Same shape as BUG-017/framework_tags_test: the sanitiser
# preserves the field perfectly, and the server never sees the gap because
# the client stops sending it before a PATCH is ever made.
class CardSubjectProvenanceTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "subj-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "S", email_address: "subj-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Subjects", theme: "Commuting", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "open_ended", "cid" => "tagged", "text" => "How was the journey in?",
          "subject" => "vintage bicycle" },
        { "type" => "open_ended", "cid" => "other", "text" => "Second question?" }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How was the journey in?"
  end

  def tagged_card
    @survey.reload.cards.find { |c| c["cid"] == "tagged" }
  end

  test "the subject reaches the editor DOM" do
    open_editor
    assert_selector "[data-card-cid='tagged'][data-card-subject='vintage bicycle']"
  end

  # The regression guard: the edit is to a DIFFERENT card, because serialize()
  # rebuilds the whole deck on every save — so a gap in it destroys provenance
  # on cards the creator never opened.
  test "editing another card does not strip the subject" do
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

    assert_equal "vintage bicycle", tagged_card["subject"], "the subject was lost on autosave"
  end

  test "editing the tagged card itself keeps its subject" do
    open_editor

    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='tagged'] .q-title")
      q.textContent = "How was your commute in?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    Timeout.timeout(15) do
      sleep 0.25 until tagged_card["text"].to_s.include?("commute")
    end

    assert_equal "vintage bicycle", tagged_card["subject"]
  end

  # The other half of carrying a field from the client: the server now
  # receives it from a PATCH, so it has to bound it rather than trust it.
  test "the server caps an oversized subject rather than trusting the client" do
    payload = [ { "type" => "open_ended", "text" => "Q?", "subject" => "x" * 500 } ]
    card = Survey.sanitize_cards_images!(payload, warnings: []).first

    assert_equal Survey::MAX_CARD_SUBJECT, card["subject"].length
  end

  test "a blank subject is dropped, not stored as an empty string" do
    payload = [ { "type" => "open_ended", "text" => "Q?", "subject" => "   " } ]
    card = Survey.sanitize_cards_images!(payload, warnings: []).first

    assert_nil card["subject"]
  end
end
