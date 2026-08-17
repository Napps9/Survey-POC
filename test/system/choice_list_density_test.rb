require "application_system_test_case"

# The editor's COUNT_RULES flags more than 5-6 options, but an imported deck
# can legitimately carry more — WLL's paper decks routinely do. Below the
# threshold nothing changes; from the 7th option on, `.choice-list` (and
# `.prioritise-list`, always the same element — see _card_component.html.erb)
# switches to a denser tile/gap/padding so a long list still fits without
# clipping, and the "more below" fade — previously mobile-only — now shows on
# desktop too. Pure CSS keyed on live child count, so this pins the rendered
# metrics rather than a class name.
class ChoiceListDensityTest < ApplicationSystemTestCase
  DENSE_TILE  = 40
  NORMAL_TILE = 56

  def survey_with(count)
    opts = (1..count).map { |i| "Option #{i}" }
    org = Organisation.create!(name: "O", slug: "density-#{SecureRandom.hex(3)}")
    s = org.surveys.create!(title: "Density", theme: "Th", audience_age: "adults",
                            key_insight: "k", default_locale: "en", locales: [ "en" ],
                            cards: [
                              { "type" => "welcome_card", "title" => "Welcome" },
                              { "type" => "multiple_choice", "cid" => "c1", "text" => "Pick one", "options" => opts }
                            ])
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s
  end

  def open(survey)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .choice-list-item", minimum: 1, wait: 5
  end

  def tile_width
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".preview-card.active .choice-list-tile")
        return el ? Math.round(el.getBoundingClientRect().width) : null
      })()
    JS
  end

  test "a five-option list keeps the normal tile size" do
    open(survey_with(5))
    assert_in_delta NORMAL_TILE, tile_width, 2, "5 options must not trigger the dense tier"
  end

  test "a ten-option list switches to the dense tile size" do
    open(survey_with(10))
    assert_in_delta DENSE_TILE, tile_width, 2, "10 options must trigger the dense tier"
  end

  test "the tenth option is present and reachable by scrolling" do
    open(survey_with(10))
    assert_selector ".preview-card.active .choice-list-item", count: 10

    last_visible = page.evaluate_script(<<~JS)
      (() => {
        const items = [...document.querySelectorAll(".preview-card.active .choice-list-item")]
        const last = items[items.length - 1]
        const scroller = last.closest(".mt-2")
        scroller.scrollTop = scroller.scrollHeight
        const r = last.getBoundingClientRect()
        const s = scroller.getBoundingClientRect()
        return r.bottom <= s.bottom + 1 && r.top >= s.top - 1
      })()
    JS
    assert last_visible, "the 10th option never scrolled into view inside its container"
  end
end
