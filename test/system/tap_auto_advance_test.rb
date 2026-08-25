require "application_system_test_case"

# The tap stack's auto-advance: answering the LAST statement moves the deck on
# after a beat, with no Next press — and deliberately doesn't when the tap card
# is the deck's final step (Finish stays an explicit act) or when Reset is hit
# during the beat. Pinned in a real browser because the behaviour IS timing:
# a dispatched event, a delay, a navigation.
class TapAutoAdvanceTest < ApplicationSystemTestCase
  def build_survey(cards)
    org = Organisation.create!(name: "O", slug: "taa-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(title: "T", theme: "Th", audience_age: "adults",
                                 key_insight: "k", default_locale: "en", locales: [ "en" ],
                                 cards: cards)
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    survey
  end

  TAP = { "type" => "tap_card", "cid" => "t1", "text" => "Swipe these",
          "options" => [ "First statement", "Second statement" ] }.freeze
  FOLLOW = { "type" => "yes_no", "cid" => "y1", "text" => "Did you enjoy it?",
             "options" => %w[Yes No] }.freeze

  # `pause_after_last: false` leaves no gap between the final answer and
  # whatever the test does next — the Reset test needs to land its click
  # inside the 900ms beat, and a sleep here would spend it.
  def answer_all_statements(pause_after_last: true)
    2.times do |i|
      within(".preview-card.active [data-tap-responses]") do
        find("[data-tap-response][data-response-key='yes']", match: :first).click
      end
      sleep 0.45 if i.zero? || pause_after_last # let the throw land before the next tap
    end
  end

  test "answering the last statement advances to the next card after a beat" do
    survey = build_survey([ TAP.dup, FOLLOW.dup ])
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner

    assert_selector ".preview-card.active[data-card-type='tap_card']"
    answer_all_statements

    # No Next press: the deck moves on by itself once the beat elapses.
    assert_selector ".preview-card.active[data-card-type='yes_no']", wait: 4
  end

  test "a tap card that ends the deck never auto-advances into Finish" do
    survey = build_survey([ TAP.dup ])
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner

    answer_all_statements
    sleep 1.6 # well past the auto-advance beat

    assert_selector ".preview-card.active[data-card-type='tap_card']",
                    text: "Swipe these"
    assert_no_selector ".preview-thankyou.active"
  end

  test "Reset during the beat cancels the advance" do
    survey = build_survey([ TAP.dup, FOLLOW.dup ])
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner

    answer_all_statements(pause_after_last: false)
    # Hitting Reset inside the 900ms beat must keep the respondent on the
    # stack, statements restored. The BUTTON's class, not a data-action
    # substring — the card wrap's relay action also contains
    # "tap-stack#reset", and a substring match clicks that inert wrap first.
    find(".preview-card.active .rotate-reset-btn").click
    sleep 1.6

    assert_selector ".preview-card.active[data-card-type='tap_card']"
    assert_selector ".preview-card.active [data-tap-response]", match: :first
  end
end
