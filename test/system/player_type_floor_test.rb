require "application_system_test_case"

# Text is not a resource the layout may spend.
#
# The mobile player is fluid — the hero, the tiles, the icons and the buttons
# all scale down from the desktop card. Type used to be on that list, and it is
# the one thing that must not be: every time a card ran short of room the words
# got smaller, so the question fell from 26px to 17px on a short phone, the
# eyebrow to 10px, and the grid option labels — the answer itself — to 11px.
# That inverts the priority. A respondent can answer a question with no
# photograph on it. They cannot answer one they cannot read.
#
# So this walks every answer type across the phones and tablets that hit the
# stacked layout and asserts nothing renders below its floor. It is the guard
# the whole change rests on: the CSS that enforces this is a handful of custom
# properties, and a single stray clamp() anywhere in 7,000 lines puts a number
# back under the line without anything else noticing.
#
# The floors are READ FROM THE CSS, not restated here — the same trick
# player_footer_test uses to measure the desktop button rather than hardcode
# it. A deliberate retune moves the token and these tests follow it; an
# accidental shrink of one element still fails.
class PlayerTypeFloorTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze

  # Every viewport that gets the stacked layout, chosen for the reason each
  # one used to break something: the Fold is the narrowest real device, the SE
  # crosses the short-viewport tier (which is where 17px came from), the 15 is
  # the phone in the bug report, sideways is the shortest, and the iPad mini is
  # the tablet that only started getting this layout recently.
  VIEWPORTS = {
    "Galaxy Fold" => [ 280, 653 ],
    "iPhone SE"   => [ 375, 553 ],
    "iPhone 15"   => [ 393, 660 ],
    "sideways"    => [ 844, 390 ],
    "iPad mini"   => [ 768, 954 ]
  }.freeze

  # No respondent-facing text goes under this, whatever else is true. Counts,
  # captions and meta furniture live here; everything they read as prose is
  # above it.
  ABSOLUTE_FLOOR = 12

  # Under 16 CSS px iOS Safari zooms the page when a field takes focus, and
  # leaves it zoomed — on a card-per-screen layout that scrolls the question
  # off and takes the footer with it.
  INPUT_FLOOR = 16

  OPTIONS = [ "Automation", "Brand building", "Measurement", "Creative craft" ].freeze

  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome", "text" => "Welcome" },
    { "type" => "multiple_choice",  "cid" => "c1", "text" => "Which one?",  "options" => OPTIONS },
    { "type" => "select_many",      "cid" => "c2", "text" => "Which ones?", "options" => OPTIONS },
    { "type" => "select_one_grid",  "cid" => "c3", "text" => "Pick a tile", "options" => OPTIONS },
    { "type" => "select_many_grid", "cid" => "c4", "text" => "Pick tiles",  "options" => OPTIONS },
    { "type" => "prioritise",       "cid" => "c5", "text" => "Rank these",  "options" => OPTIONS },
    { "type" => "rating",           "cid" => "c6", "text" => "Rate it",     "options" => [ "Poor", "Great" ] },
    { "type" => "range",            "cid" => "c7", "text" => "How confident?",
      "options" => [ "Not at all", "A little", "Somewhat", "Fairly", "Very" ] },
    { "type" => "nps",              "cid" => "c8", "text" => "Would you recommend us?" },
    { "type" => "yes_no",           "cid" => "c9", "text" => "Would you come?" },
    { "type" => "open_ended",       "cid" => "c10", "text" => "Anything else?" }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "floor-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Floors", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # Cuprite keeps one browser for the whole run, so a test that resizes and
  # doesn't put it back breaks every later test that assumed the default.
  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_at(width, height, root_font: nil)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    page.execute_script("document.documentElement.style.fontSize = '#{root_font}'") if root_font
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  # The floors, as the stylesheet states them, in resolved pixels.
  #
  # NOT parseFloat(getPropertyValue("--play-label")): a custom property's value
  # is the token as authored, so that reads "1rem" and hands back 1, and every
  # comparison against it passes for free. Worse, the tablet tier's
  # clamp(1.625rem, 3.4vw, 2rem) parses to NaN, so the test errors instead of
  # silently passing — which is the only reason this was caught.
  #
  # Assigning the var to a real element and reading back its computed
  # font-size makes the browser resolve rem, vw and clamp exactly as it does
  # for the elements being checked.
  def floors
    page.evaluate_script(<<~JS)
      (() => {
        const probe = document.createElement("span")
        probe.style.position = "absolute"
        probe.style.visibility = "hidden"
        document.querySelector(".preview-overlay").appendChild(probe)
        const px = (v) => {
          probe.style.fontSize = `var(${v})`
          return parseFloat(getComputedStyle(probe).fontSize)
        }
        const out = { title: px("--play-title"), subtitle: px("--play-subtitle"),
                      eyebrow: px("--play-eyebrow"), label: px("--play-label") }
        probe.remove()
        return out
      })()
    JS
  end

  # Every text node the respondent actually reads on the active card, with the
  # size it computed to. Elements with no text are skipped: an empty span has
  # no legibility to lose, and several of these are placeholders the card only
  # fills in for some types.
  def type_sizes
    page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        if (!card) return []
        const SELECTORS = {
          eyebrow:   ".q-eyebrow",
          title:     ".q-title",
          subtitle:  ".q-subtitle",
          label:     ".choice-label, .choice-list-label, .pick-text, .slider-label-text",
          control:   ".preview-btn:not(.hidden)",
          input:     ".freeform-textarea, .contact-field, .location-search-field",
          other:     ".other-cta-btn",
          counter:   ".freeform-counter"
        }
        const out = []
        for (const [role, sel] of Object.entries(SELECTORS)) {
          const scope = role === "control" ? document : card
          for (const el of scope.querySelectorAll(sel)) {
            const cs = getComputedStyle(el)
            if (cs.display === "none" || cs.visibility === "hidden") continue
            // A collapsed footer button is font-size:0 ON PURPOSE — the label
            // is hidden so a pseudo-element can draw an arrow in its place,
            // which is the legible answer, not a shrunken one.
            if (el.classList.contains("preview-btn") &&
                el.closest(".preview-footer")?.classList.contains("is-tight")) continue
            const text = (el.value ?? el.textContent ?? "").trim()
            if (!text && !el.matches("textarea, input")) continue
            // The documented exception, recognised HERE rather than at assert
            // time: the deck has been walked to its last card by then, so
            // asking the page "is this NPS?" afterwards always answers about
            // the wrong card. NPS labels the digits 0-10 down a fixed-height
            // column where 16px would collide; they still owe the absolute
            // floor, just not the answer-label one.
            const r = (role === "label" && el.closest(".nps-slider-labels")) ? "nps-scale" : role
            out.push({ role: r, size: parseFloat(cs.fontSize),
                       tag: el.className.toString().split(" ")[0] })
          }
        }
        return out
      })()
    JS
  end

  # Walk the whole deck at one viewport, collecting every text size on the way.
  def sizes_through_deck
    seen = []
    seen.concat(type_sizes)
    (CARDS.length - 1).times do
      break unless page.has_css?(".preview-btn-next:not(.hidden)", wait: 2)
      find(".preview-btn-next:not(.hidden)").click
      sleep 0.35
      seen.concat(type_sizes)
    end
    seen
  end

  VIEWPORTS.each do |name, (w, h)|
    test "nothing on a card at #{name} (#{w}x#{h}) renders below its floor" do
      open_at(w, h)
      floor = floors
      seen  = sizes_through_deck

      assert_operator seen.length, :>, 20, "the walk collected almost nothing — it probably didn't advance"

      seen.each do |el|
        role, size, tag = el["role"], el["size"], el["tag"]

        assert_operator size, :>=, ABSOLUTE_FLOOR,
                        "#{name}: .#{tag} (#{role}) rendered at #{size}px — nothing goes under #{ABSOLUTE_FLOOR}"

        case role
        when "title"    then assert_operator size, :>=, floor["title"],    "#{name}: the question fell below --play-title"
        when "subtitle" then assert_operator size, :>=, floor["subtitle"], "#{name}: .#{tag} fell below --play-subtitle"
        when "eyebrow"  then assert_operator size, :>=, floor["eyebrow"],  "#{name}: .#{tag} fell below --play-eyebrow"
        when "label"
          assert_operator size, :>=, floor["label"],
                          "#{name}: .#{tag} is answer text and fell below --play-label"
        when "input"
          assert_operator size, :>=, INPUT_FLOOR,
                          "#{name}: .#{tag} is #{size}px — iOS Safari zooms the page under #{INPUT_FLOOR}"
        end
      end
    end
  end

  # The reason for rem. Every respondent-facing size is expressed against the
  # root, so a browser set to larger text scales the card with it — and this is
  # what fails the moment someone writes a px literal back in.
  test "a raised browser font-size actually raises the text" do
    open_at(393, 660)
    at_default = sizes_through_deck.group_by { |e| e["role"] }
                                   .transform_values { |v| v.map { |e| e["size"] }.min }

    open_at(393, 660, root_font: "20px")
    at_raised = sizes_through_deck.group_by { |e| e["role"] }
                                  .transform_values { |v| v.map { |e| e["size"] }.min }

    # 20/16 = 1.25. Allow a little slack for anything legitimately clamped.
    #
    # The question and the answer labels, deliberately — not the footer
    # buttons. At 20px their labels stop fitting the bar and _fitFooter
    # collapses them to arrows, which is the right answer and would read here
    # as text that failed to grow. The controls get their own test below.
    %w[title label].each do |role|
      assert at_default[role] && at_raised[role], "no #{role} text was collected"
      assert_operator at_raised[role], :>, at_default[role] * 1.15,
                      "#{role} text ignored the browser's font-size setting " \
                      "(#{at_default[role]}px → #{at_raised[role]}px) — it is sized in px, not rem"
    end
  end

  # Bigger text must not be allowed to push the controls off the screen: the
  # card sheds its pictures to pay for it, which is the whole priority order.
  test "the controls survive a raised browser font-size" do
    open_at(375, 553, root_font: "20px")
    find(".preview-btn-next:not(.hidden)").click
    sleep 0.4

    assert page.evaluate_script(<<~JS), "Back and Next left the screen when the text grew"
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
end
