require "application_system_test_case"

# "No going back" in the browser: the footer Back is gone outright (not the
# dimmed "nowhere to go" ghost), the card just left is locked, and every
# advance is saved so the server holds each answer it pins. A scenario card
# keeps its own page chevrons — re-reading a story page changes no answer.
class PlayerNoGoingBackTest < ApplicationSystemTestCase
  def setup
    super
    @org = Organisation.create!(name: "O", slug: "ngb-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Rules", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], no_going_back: true,
      cards: [
        { "type" => "multiple_choice", "cid" => "q1", "text" => "First question", "options" => [ "Alpha", "Beta" ] },
        { "type" => "multiple_choice", "cid" => "q2", "text" => "Second question", "options" => [ "Gamma", "Delta" ] },
        { "type" => "scenario", "cid" => "sc1", "text" => "What would you do?",
          "options" => [ "Speak up", "Say nothing" ],
          "pages" => (1..2).map { |i| { "id" => "pg#{i}", "text" => "Page #{i} of the story." } } },
        { "type" => "multiple_choice", "cid" => "q3", "text" => "Last question", "options" => [ "Eps", "Zeta" ] }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def back_hidden?
    page.evaluate_script("document.querySelector('.preview-btn-back').classList.contains('hidden')")
  end

  def card_locked?(text)
    page.evaluate_script(<<~JS)
      (() => {
        const card = Array.from(document.querySelectorAll('.preview-card')).find(c => c.textContent.includes(#{text.to_json}))
        const list = card && card.querySelector('.choice-list, .choice-grid')
        return !!list && list.style.pointerEvents === 'none'
      })()
    JS
  end

  test "Back is hidden, the card left behind is locked, and every advance reaches the server" do
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_text "First question"
    assert back_hidden?, "hidden outright, not the 0.35-opacity ghost"
    assert_not card_locked?("First question")

    find(".choice-list-item", text: "Alpha").click
    find(".preview-btn-next").click
    assert_text "Second question"
    assert back_hidden?
    assert card_locked?("First question"), "the card just left is locked as it is left"

    row = wait_for_answer("0")
    assert_equal "Alpha", row.answers.dig("0", "value"), "the first advance is on the server before the second card is answered"

    find(".choice-list-item", text: "Gamma").click
    find(".preview-btn-next").click
    row = wait_for_answer("1")
    assert_equal "Gamma", row.answers.dig("1", "value"), "and so is the second — every advance saves, not only the first"

    # The scenario card: its own pages still turn both ways, because hiding
    # the deck's Back changes nothing about re-reading a story.
    assert_text "Page 1 of the story."
    find(".preview-card.active [data-action='click->scenario#next']", match: :first).click
    assert_text "Page 2 of the story."
    find(".preview-card.active [data-action='click->scenario#back']", match: :first).click
    assert_text "Page 1 of the story."
    assert back_hidden?
  end

  private

  def wait_for_answer(key)
    deadline = Time.current + 8
    loop do
      row = @survey.responses.reload.first
      return row if row && row.answers.is_a?(Hash) && row.answers.key?(key)
      raise "no stored answer for card #{key} after 8s" if Time.current > deadline
      sleep 0.2
    end
  end
end
