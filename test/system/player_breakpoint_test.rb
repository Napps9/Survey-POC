require "application_system_test_case"

# Which layout the player picks at each shape of screen.
#
# The rule is not "is this a phone" — it is "can this viewport hold the
# desktop card", which is a fixed 850 x 680 box. Those came apart on a
# portrait iPad: 768px wide is one pixel past a breakpoint chosen for phones,
# so it got a 680px card floating in a 954px screen. Pinned here because a
# media query with three clauses is exactly the sort of thing that gets
# "tidied" back into one.
class PlayerBreakpointTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze

  # name, width, height, expected layout
  SHAPES = [
    [ "iPhone SE portrait",       375,  553,  :stacked ],
    [ "iPhone 15 portrait",       393,  660,  :stacked ],
    [ "iPhone 15 landscape",      844,  390,  :stacked ],
    [ "iPad mini portrait",       768,  954,  :stacked ],
    [ "iPad Pro 12.9 portrait",  1024, 1290,  :stacked ],
    [ "iPad mini landscape",     1024,  714,  :split   ],
    [ "laptop",                  1280,  800,  :split   ]
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "bp-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Breakpoint", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Welcome" },
                                     { "type" => "select_many_grid", "cid" => "c1",
                                       "text" => "Which themes?", "image" => "/nope.jpg",
                                       "options" => %w[One Two Three Four Five Six] }
                                   ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  # The stacked layout is a column; the desktop card is a row. Reading the
  # computed flex-direction asks the layout what it is rather than inferring
  # it from a width we already know.
  def layout_at(width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # onto the card with a hero image
    dir = page.evaluate_script(
      "getComputedStyle(document.querySelector('.preview-card.active .split-card')).flexDirection"
    )
    dir == "column" ? :stacked : :split
  end

  SHAPES.each do |name, width, height, expected|
    test "#{name} (#{width}x#{height}) gets the #{expected} layout" do
      assert_equal expected, layout_at(width, height)
    end
  end

  # The specific regression: 768 is one pixel past the old 767px breakpoint,
  # which is how an iPad ended up on the desktop card in the first place.
  test "the boundary sits between a portrait tablet and a landscape one" do
    assert_equal :stacked, layout_at(768, 1024), "a tablet held upright is a tall narrow screen"
    assert_equal :split,   layout_at(1024, 768), "the same tablet turned sideways suits the wide card"
  end

  # Widening the PLAYER's breakpoint must not drag the studio's own chrome
  # into a phone layout with it — the editor is built for a pointer.
  test "the studio keeps its desktop chrome on a portrait tablet" do
    page.driver.browser.resize(width: 768, height: 1024)
    visit "/play/#{@survey.publish_token}"

    # .wizard-mobile-hint is display:none by default and display:block only
    # inside the phone-only block, so it answers "did the studio's half of the
    # old media query come along too?" without needing the editor on screen.
    assert_equal "none", page.evaluate_script(<<~JS)
      (() => {
        const el = document.createElement("div")
        el.className = "wizard-mobile-hint"
        document.body.appendChild(el)
        const d = getComputedStyle(el).display
        el.remove()
        return d
      })()
    JS
  end
end
