require "application_system_test_case"

# The "Aa" pill (default/large/larger) — a respondent's own reading
# preference, not a creator setting. Pins three things: the computed size on
# a reading surface actually changes while the footer chrome does not, a
# card that would otherwise leave the controls off-screen once the text
# grows sheds its artwork to make room (the same _fitCard priority order
# player_type_floor_test already covers for a raised BROWSER font-size —
# this is the same mechanism via the in-page pill instead), and the choice
# persists across a fresh visit.
class PlayerFontScaleTest < ApplicationSystemTestCase
  OPTIONS = [ "Automation", "Brand building", "Measurement", "Creative craft" ].freeze
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "select_one_grid", "cid" => "c1", "text" => "Pick a tile", "options" => OPTIONS }
  ].freeze

  DESKTOP = [ 1280, 900 ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "fscale-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "FontScale", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player(width: DESKTOP[0], height: DESKTOP[1])
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  def computed_size(selector)
    evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(#{selector.to_json})
        return el ? parseFloat(getComputedStyle(el).fontSize) : null
      })()
    JS
  end

  test "the pill grows a reading surface without touching the footer" do
    open_player
    click_button "Next" # past welcome, onto the grid question

    title_before  = computed_size(".preview-card.active .q-title")
    footer_before = computed_size(".preview-footer .preview-btn:not(.hidden)")
    assert title_before, "no .q-title to measure"
    assert footer_before, "no visible footer button to measure"

    find(".font-scale-btn[data-scale='larger']").click

    title_after  = computed_size(".preview-card.active .q-title")
    footer_after = computed_size(".preview-footer .preview-btn:not(.hidden)")

    assert_operator title_after, :>, title_before, "the question title didn't grow"
    assert_in_delta footer_before, footer_after, 0.1,
                    "footer button text must never scale with the reading-surface pill"
    assert_equal "larger", find(".preview-overlay")["data-font-scale"]
    assert_equal "true", find(".font-scale-btn[data-scale='larger']")["aria-pressed"]
  end

  # Mirrors player_type_floor_test's "the controls survive a raised browser
  # font-size" — same claim, this control instead of the root font-size.
  #
  # The preference is seeded rather than clicked because the pill is hidden on
  # phones now (the strip it lived in was costing every card ~44px, which the
  # 45/55 split reclaimed) — and this test is specifically about a PHONE. The
  # claim is unchanged and, if anything, matters more than before: a taller
  # hero leaves less room, so this is the first place an over-eager 45/55
  # would show up. Seeding is also how a phone respondent genuinely arrives at
  # "larger" now — they set it on a desktop and _loadFontScale reads it back
  # out of localStorage on connect.
  test "the controls survive the larger step by shedding artwork, not by clipping" do
    open_player(width: 375, height: 553)
    page.execute_script("localStorage.setItem('verto_font_scale', 'larger')")
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"

    assert_equal "larger", find(".preview-overlay")["data-font-scale"],
                 "the stored preference must still apply on a phone even though the pill is hidden"
    sleep 0.4 # _fitCard's re-measure

    assert page.evaluate_script(<<~JS), "Back and Next/Finish left the screen once the text grew"
      (() => {
        const on = (el) => {
          if (!el) return false
          const r = el.getBoundingClientRect()
          return r.width > 0 && r.height > 0 && r.bottom <= window.innerHeight + 1 && r.top >= 0
        }
        return on(document.querySelector(".preview-btn-next:not(.hidden), .preview-btn-finish:not(.hidden)")) &&
               on(document.querySelector(".preview-btn-back"))
      })()
    JS
  end

  test "the choice persists across a fresh visit" do
    open_player
    find(".font-scale-btn[data-scale='large']").click
    assert_equal "large", evaluate_script("localStorage.getItem('verto_font_scale')")

    visit "/play/#{@survey.publish_token}"
    assert_equal "large", find(".preview-overlay")["data-font-scale"]
    assert_equal "true", find(".font-scale-btn[data-scale='large']")["aria-pressed"]
    assert_equal "false", find(".font-scale-btn[data-scale='default']")["aria-pressed"]
  end
end
