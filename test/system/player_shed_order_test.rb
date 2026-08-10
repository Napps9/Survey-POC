require "application_system_test_case"

# What the player can afford, and what it gives up when it can't.
#
# The rule is a priority, not a fallback: a respondent can answer a question
# with no artwork on it and cannot answer one whose options are off the bottom
# of the screen. So the pictures are what go, and the answer widget and the
# footer are never touched.
#
# _fitCard budgets UP rather than stripping down — it starts from the
# undecorated answer, prices that as the debt, and buys back the option
# artwork and then the hero only while neither adds to it. What this file
# asserts is the outcome, which is the same either way and is the part worth
# pinning: the artwork goes before the options do, every option survives, the
# footer survives, and the card climbs again when the room comes back.
#
#   .art-off   — the option tiles go, the grid becomes the option list
#   .hero-off  — the card image goes
#   then whatever is still too tall scrolls
class PlayerShedOrderTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze
  ROOMY   = [ 1024, 1290 ].freeze  # iPad Pro upright — everything fits
  TIGHT   = [ 844,  390 ].freeze   # a phone turned sideways

  SIX    = [ "AI and automation", "Brand building", "Measurement",
             "Creative craft", "Leadership", "Sustainability" ].freeze
  TWELVE = (SIX + [ "Media planning", "Customer insight", "Pricing strategy",
                    "Internal comms", "Partnerships", "Retail and commerce" ]).freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "shed-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Shed", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Welcome" },
                                     { "type" => "select_many_grid", "cid" => "c1",
                                       "text" => "Which themes should we build more sessions around?",
                                       "image" => "/nope.jpg", "options" => SIX },
                                     { "type" => "select_many_grid", "cid" => "c2",
                                       "text" => "Which of these twelve topics would you attend?",
                                       "image" => "/nope.jpg", "options" => TWELVE }
                                   ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_at(width, height, card: 1)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    card.times { click_button "Next" }
    # the ladder is measured a frame after the card lands
    sleep 0.4
  end

  def rung
    page.evaluate_script(<<~JS)
      (() => {
        const c = document.querySelector(".preview-card.active")
        const g = c.querySelector(".choice-grid")
        if (c.classList.contains("hero-off")) return 3
        if (g && g.classList.contains("art-off")) return 2
        return 1
      })()
    JS
  end

  def controls_usable?
    page.evaluate_script(<<~JS)
      (() => {
        const next = document.querySelector(".preview-btn-next:not(.hidden), .preview-btn-finish:not(.hidden)")
        const back = document.querySelector(".preview-btn-back")
        const on = el => {
          if (!el) return false
          const r = el.getBoundingClientRect()
          const s = getComputedStyle(el)
          return r.width > 0 && r.height > 0 && s.display !== "none" && s.visibility !== "hidden" &&
                 r.bottom <= window.innerHeight + 1 && r.top >= 0
        }
        return on(next) && on(back)
      })()
    JS
  end

  test "a card that fits gives up nothing" do
    open_at(*ROOMY)

    assert_equal 1, rung, "there was room for the artwork — it should still be there"
  end

  # Six options with short labels now fit a sideways phone as drawn, since a
  # wide panel gets three columns rather than the phone's two. Twelve is the
  # case that still cannot: 390px of height, and no arrangement of twelve
  # image tiles fits in it.
  test "a sideways phone loses the pictures rather than the options" do
    open_at(*TIGHT, card: 2)

    assert_operator rung, :>=, 2, "twelve image tiles do not fit here; the pictures should have gone"
    assert_equal 12, page.all(".preview-card.active .choice-card", visible: :all).length,
                 "every option must survive — it is the artwork that is expendable"
  end

  test "twelve options on a phone shed both the tiles and the hero" do
    open_at(375, 553, card: 2)

    assert_equal 3, rung, "twelve options need everything the card can give them"
    assert page.has_no_css?(".preview-card.active .split-left-img", visible: true),
           "the hero image should be gone, not merely small"
  end

  # The whole point of the ordering. Whatever else is given up, these are not.
  [ ROOMY, TIGHT, [ 375, 553 ], [ 280, 653 ] ].each do |w, h|
    test "Back and Next stay on screen and usable at #{w}x#{h}" do
      open_at(w, h, card: 2)

      assert controls_usable?,
             "the footer is never on the list of things to give up (rung #{rung})"
    end
  end

  # Shedding is not a one-way door: rotate back and the artwork returns. The
  # assertion is that it climbs, not that it reaches any particular rung —
  # where it lands is a matter of how much room the bigger screen actually has.
  test "the artwork comes back when the room does" do
    open_at(*TIGHT, card: 2)
    stripped = rung
    assert_operator stripped, :>=, 2

    page.driver.browser.resize(width: ROOMY[0], height: ROOMY[1])
    sleep 0.6

    assert_operator rung, :<, stripped,
                    "a card stripped for space should give some of it back when the room returns"
  end
end
