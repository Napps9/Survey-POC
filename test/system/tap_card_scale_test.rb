require "application_system_test_case"

# A tap card on a scale wider than the historic three (TapScales).
#
# tap_card_swipe_test covers the gesture on the default three; this covers what
# changes when a creator picks five: the strip becomes pills, every one of them
# answers, and a fling — which can only ever express three intents — commits the
# EXTREME on the side it went, rather than rounding to a neighbour the
# respondent didn't choose.
#
# Same Cuprite constraint as the swipe test: no touch synthesis, so the drags are
# synthetic PointerEvents on exactly the targets the controller listens to.
class TapCardScaleTest < ApplicationSystemTestCase
  STATEMENTS = [ "Meetings drain me", "I get deep work done", "Fridays are calm" ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "scale-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Scale", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Welcome" },
                                     { "type" => "tap_card", "cid" => "c1", "text" => "React to these",
                                       "options" => STATEMENTS,
                                       "responses" => TapScales.preset(5) }
                                   ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def open_tap_card
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .rotate-card", count: 3, wait: 5
  end

  def results
    JSON.parse(evaluate_script(
      "document.querySelector('.preview-card.active .rotate-wrap')?.dataset?.swipeResults || '{}'"
    ))
  end

  # The top card is the first whose INLINE opacity isn't "0" — _commit zeroes the
  # flung card synchronously, whereas computed opacity lags the 350ms fling.
  def top_card_statement
    evaluate_script(<<~JS)
      (() => {
        const cards = [...document.querySelectorAll('.preview-card.active .rotate-card')]
        const top = cards.find((c) => c.style.opacity !== '0')
        return top ? top.querySelector('.rotate-card-statement span').textContent.trim() : null
      })()
    JS
  end

  def fling(dx: 0, dy: 0)
    execute_script(<<~JS, dx, dy)
      const [fx, fy] = arguments
      const cards = [...document.querySelectorAll('.preview-card.active .rotate-card')]
      const card = cards.find((c) => c.style.opacity !== '0')
      const box = card.getBoundingClientRect()
      const x0 = box.left + box.width / 2, y0 = box.top + box.height / 2
      const dx = Math.abs(fx) > 1 ? fx : box.width * fx
      const dy = Math.abs(fy) > 1 ? fy : box.height * fy
      const ev = (type, x, y) => card.dispatchEvent(
        new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 7, clientX: x, clientY: y }))
      ev('pointerdown', x0, y0)
      window.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, pointerId: 7, clientX: x0 + dx, clientY: y0 + dy }))
      window.dispatchEvent(new PointerEvent('pointerup',   { bubbles: true, pointerId: 7, clientX: x0 + dx, clientY: y0 + dy }))
    JS
  end

  test "a five-point scale renders as pills, one per response" do
    open_tap_card

    assert_selector ".preview-card.active .rotate-actions--pills", wait: 3
    assert_selector ".preview-card.active [data-tap-response]", count: 5
    assert_equal TapScales.preset(5).map { |r| r["label"] },
                 all(".preview-card.active [data-tap-response] .rotate-action-label").map(&:text)
  end

  test "every pill answers, including the ones no gesture can reach" do
    open_tap_card

    # "Disagree" and "Agree" are the two a fling can never land on — they are
    # the whole reason the strip is tappable rather than swipe-only.
    %w[disagree neutral agree].each do |key|
      statement = top_card_statement
      find(".preview-card.active [data-response-key='#{key}']").click
      assert_equal key, results[statement], "tapping #{key} must record #{key}"
    end
  end

  test "a fling commits the extreme on the side it went, not a neighbour" do
    open_tap_card

    first = top_card_statement
    fling(dx: 0.35)
    assert_equal "strongly_agree", results[first],
                 "a right fling on a five-point scale means the most positive answer"

    second = top_card_statement
    fling(dx: -0.35)
    assert_equal "strongly_disagree", results[second],
                 "a left fling means the most negative answer"
  end

  test "a fling upward lands on the middle of an odd scale" do
    open_tap_card
    first = top_card_statement

    fling(dy: -0.30)
    assert_equal "neutral", results[first],
                 "the middle of an odd scale is what an upward fling has always meant"
  end
end
