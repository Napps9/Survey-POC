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

  # This used to assert the opposite — that a badge cost a row NOTHING in
  # height, the chip riding along beside the label. That held while options were
  # a word or two. A creator writing the trade-off into each option found the
  # chip taking the width their sentence needed, because it is flex-shrink:0 and
  # nowrap and the label is the only thing in the row that can yield. So the
  # chip moved under the words, and the row grows to fit it — which is the
  # change, and therefore what this now pins.
  test "the amounts sit under the option's words, and the row grows to fit them" do
    open_deck!
    row = find(".preview-card.active [data-canonical='Pizza']")
    settle_box(row)

    boxes = page.evaluate_script(<<~JS)
      (() => {
        const li    = document.querySelector(".preview-card.active [data-canonical='Pizza']")
        const label = li.querySelector(".choice-list-label")
        const chip  = li.querySelector(".token-option-badge")
        const r = el => { const b = el.getBoundingClientRect(); return { top: b.top, bottom: b.bottom, left: b.left } }
        return { label: r(label), chip: r(chip) }
      })()
    JS

    assert_operator boxes["chip"]["top"], :>=, boxes["label"]["bottom"] - 1,
                    "the chip must start below the last line of the label, not beside it"
    assert_in_delta boxes["label"]["left"], boxes["chip"]["left"], 1,
                    "the chip lines up with the words it belongs to"

    heights = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".preview-card.active .choice-list-item"))
           .map(li => Math.round(li.getBoundingClientRect().height))
    JS
    assert_equal 3, heights.size
    # Pizza and Salad carry amounts, Water does not. Paying for the chip in
    # height is the point; the unbadged row is what it always was.
    assert_operator heights.max, :>, heights.min,
                    "a badged row should now be taller than the plain one: #{heights.inspect}"
  end

  # The case the change was reported for: an option carrying the sentence that
  # explains its trade-off. On the old row the chip took that sentence's width
  # and would not give it back, because it is flex-shrink:0 and nowrap and the
  # label is the only thing in the row that can yield.
  LONG = "Buy the cold water because it is hot outside and the walk back is a long one"

  test "a long option keeps the full column, and the row still fits the phone" do
    @survey.update!(cards: [ { "type" => "multiple_choice", "cid" => "q1", "text" => "First pick",
                               "options" => [ LONG, "Water" ],
                               "tokens" => { LONG => { "gold" => 3, "lives" => 4 } } } ])
    open_deck!
    settle_box(find(".preview-card.active .choice-list-item", match: :first))

    m = page.evaluate_script(<<~JS)
      (() => {
        const li    = document.querySelector(".preview-card.active .choice-list-item")
        const label = li.querySelector(".choice-list-label")
        const chip  = li.querySelector(".token-option-badge")
        const stack = li.querySelector(".choice-list-labels")
        return {
          label: label.getBoundingClientRect().width,
          stack: stack.getBoundingClientRect().width,
          chipTop: chip.getBoundingClientRect().top,
          labelBottom: label.getBoundingClientRect().bottom,
          overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
        }
      })()
    JS

    # The words get the column. Anything much under this and the chip is back to
    # taking width the sentence needed.
    assert_operator m["label"] / m["stack"], :>, 0.9,
                    "a long label should have the whole column: #{m.inspect}"
    assert_operator m["chipTop"], :>=, m["labelBottom"] - 1,
                    "the chip stays under the words, not beside them"
    assert_operator m["overflow"], :<=, 1, "nothing may push the page sideways: #{m.inspect}"
  end
end
