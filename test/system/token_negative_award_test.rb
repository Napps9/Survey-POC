require "application_system_test_case"

# Tokens as lives: an option can cost points as well as earn them, and the
# player has to say so. The after-answer reveal used to drop negative awards
# (it filtered for gains) while the running total still fell; and every number
# rendered raw. Now a loss shows with its sign in a red-tinted reveal, and
# totals carry thousands separators everywhere they appear. Only a browser can
# pin this — the amounts are computed and rendered client-side.
class TokenNegativeAwardTest < ApplicationSystemTestCase
  TYPES = [
    { "id" => "gold",  "name" => "Coins", "icon" => "🪙" },
    { "id" => "lives", "name" => "Lives", "icon" => "❤️" }
  ].freeze
  CARDS = [
    { "type" => "multiple_choice", "cid" => "q1", "text" => "First pick", "options" => %w[Pizza Salad Water],
      "tokens" => { "Pizza" => { "gold" => 500000 }, "Salad" => { "lives" => -1 } } },
    { "type" => "multiple_choice", "cid" => "q2", "text" => "Second pick", "options" => %w[Left Right] }
  ].freeze

  def setup
    super
    org = Organisation.create!(name: "O", slug: "tna-#{SecureRandom.hex(3)}")
    @survey = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                                  tokenisation_enabled: true, token_types: TYPES,
                                  token_reveal_enabled: true, token_hud_enabled: true, token_amounts_shown: true,
                                  publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def open_deck!
    visit play_survey_path(@survey.publish_token)
    dismiss_cookie_banner
    assert_selector ".preview-card.active", wait: 5
    assert_text "First pick"
  end

  def pick_and_advance!(label)
    find(".preview-card.active .pick-item", text: label).click
    find(".preview-btn-next").click
    assert_text "Second pick"
  end

  test "a gain is formatted with thousands separators in the reveal and the running total" do
    open_deck!
    assert_selector "[data-canonical='Pizza'] .token-option-badge", text: "🪙 500,000"
    pick_and_advance!("Pizza")

    # The reveal is appended to the card being LEFT, so it is no longer the
    # visible card.
    assert_selector ".preview-card[data-card-index='0'] .token-reveal.is-earned .token-reveal-rows",
                    text: "🪙 Coins +500,000", visible: :all
    assert_selector ".token-score-pill", text: "🪙 500,000"
  end

  test "a loss is shown with its sign, in a red-tinted reveal, and the total goes negative" do
    open_deck!
    assert_selector "[data-canonical='Salad'] .token-option-badge", text: "❤️ -1"
    pick_and_advance!("Salad")

    assert_selector ".preview-card[data-card-index='0'] .token-reveal.is-lost .token-reveal-rows",
                    text: "❤️ Lives -1", visible: :all
    assert_selector ".token-score-pill", text: "❤️ -1"
    assert_selector ".token-score-pill", text: "🪙 0"
  end

  test "a badge does not change the height of an option row" do
    open_deck!
    heights = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".preview-card.active .choice-list-item"))
           .map(li => Math.round(li.getBoundingClientRect().height))
    JS
    assert_equal 3, heights.size
    # Sub-pixel rounding can split neighbours by a pixel; a badge that grew its
    # row would show as several pixels.
    assert_operator heights.max - heights.min, :<=, 1,
                    "badged rows (Pizza, Salad) must match the plain row (Water): #{heights.inspect}"
  end
end
