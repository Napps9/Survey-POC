require "application_system_test_case"

# A scenario's story is set in the middle of its page, both ways.
#
# The leaf is a fixed white rectangle and a story page is usually two or three
# sentences, so left-and-top alignment left the words huddled in one corner of
# it with the page number alone in the other — type pushed into the gutter
# rather than set on the page.
#
# Centring text inside a scroller is the kind of change that works on the
# example everyone looks at and fails on the one nobody does: a centred flex
# line puts its overflow at BOTH ends, so a page whose story runs long would
# push its first lines above scroll-top, where there is no negative scroll
# position to reach them. That is the whole reason `safe` exists, and it is why
# this measures the long page as carefully as the short one.
#
# It also measures WHERE THE TEXT IS rather than which properties are set, so
# the guard survives someone reaching the same layout by another route.
class ScenarioPageCentringTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze

  SHORT = "The studio is free for an hour and nobody has held a camera before.".freeze
  # Long enough to outgrow the leaf at any of the sizes this runs at.
  LONG  = ([ "You have been asked to run a session for eight young people who " \
             "have never used a camera before, and the studio is free for one hour." ] * 12).join(" ").freeze

  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "title" => "Welcome", "text" => "Welcome" },
    { "type" => "scenario", "cid" => "s1", "text" => "What do you do?",
      "options" => [ "Start anyway", "Reschedule" ],
      "pages" => [ { "id" => "p1", "text" => SHORT } ] },
    { "type" => "scenario", "cid" => "s2", "text" => "And then?",
      "options" => [ "Ask for help", "Carry on" ],
      "pages" => [ { "id" => "p2", "text" => LONG } ] },
    # Same book markup, deliberately NOT centred: an information sheet is
    # written to be read carefully, and centred prose is the wrong setting.
    { "type" => "consent_gate", "cid" => "c1", "text" => "Before we start",
      "pages" => [ { "id" => "cp1", "text" => "Taking part is voluntary and you can stop at any time." } ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "book-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Book", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"   # past the welcome card
    assert_selector ".preview-card.active .book-page-text", wait: 5
  end

  # The card entry animation transforms the whole card; anything measured while
  # it plays is geometry no respondent ever sees.
  def settle
    page.has_no_css?(".preview-card.active.is-entering", wait: 2)
    sleep 0.25
  end

  # A book card does not answer to Next until its pages have been turned — the
  # footer button only moves the DECK on once the book is on its choice page.
  # So reaching anything after a scenario means turning to the end of it first.
  def turn_to_choice_page
    8.times do
      at_end = page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector(".preview-card.active")
          const fwd  = card.querySelector(".book-nav-row .book-chevron:last-of-type")
          if (!fwd || fwd.disabled) return true
          fwd.click()
          return false
        })()
      JS
      break if at_end
      settle
    end
  end

  def next_card
    turn_to_choice_page
    click_button "Next"
    settle
  end

  # Where the story actually sits inside the page it is on.
  def page_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const card   = document.querySelector(".preview-card.active")
        const scroll = card.querySelector(".book-page:not(.is-answer) .book-page-scroll")
        const text   = scroll.querySelector(".book-page-text")
        const s  = scroll.getBoundingClientRect()
        const t  = text.getBoundingClientRect()
        const cs = getComputedStyle(scroll)
        // What is centred is the kicker AND the story — the block of type on
        // the page — so the measurement is the space above that block against
        // the space below it, inside the page's content box. Equal space either
        // side IS centred, and it says so without caring how it was done.
        const kids   = [ ...scroll.children ].map(k => k.getBoundingClientRect())
        const top    = Math.min(...kids.map(k => k.top))
        const bottom = Math.max(...kids.map(k => k.bottom))
        // `|| 0` because Math.round(-0.2) is NEGATIVE zero, and negative zero
        // comes back over CDP as nil rather than 0 — an assertion that then
        // fails against a layout that is exactly right.
        const px = (n) => Math.round(n) || 0
        return {
          type:        card.dataset.cardType,
          textAlign:   getComputedStyle(text).textAlign,
          overflow:    scroll.scrollHeight - scroll.clientHeight,
          scrollTop:   scroll.scrollTop,
          spaceAbove:  px(top - (s.top + parseFloat(cs.paddingTop))),
          spaceBelow:  px((s.bottom - parseFloat(cs.paddingBottom)) - bottom),
          firstLineIn: t.top >= s.top - 1
        }
      })()
    JS
  end

  test "a story page sets its type in the middle of the leaf" do
    open_player
    settle
    g = page_geometry

    assert_equal "scenario", g["type"], "sanity: the first card after welcome is the short scenario"
    assert_equal "center", g["textAlign"], "the story reads centred across the page"
    assert_equal 0, g["overflow"], "sanity: this page is short enough to fit, so centring is what we see"
    assert_in_delta g["spaceAbove"], g["spaceBelow"], 2,
      "the story should sit in the middle of the leaf, not at the top of it " \
      "(#{g['spaceAbove']}px above, #{g['spaceBelow']}px below)"
  end

  test "a story too long for the leaf starts at its first line" do
    open_player
    settle
    next_card            # onto the long scenario
    g = page_geometry

    assert_operator g["overflow"], :>, 0,
      "sanity: this page is meant to be longer than the leaf"
    assert_equal 0, g["scrollTop"], "a page opens at its beginning"
    assert g["firstLineIn"],
      "centring must never push the first lines above scroll-top — there is no " \
      "negative scroll position to bring them back"
  end

  test "the consent gate keeps its information sheet left and top" do
    open_player
    settle
    2.times { next_card }   # past both scenarios, onto the gate
    g = page_geometry

    assert_equal "consent_gate", g["type"], "sanity: landed on the gate"
    assert_equal "left", g["textAlign"], "consent copy is prose to read, not a title to centre"
    assert_equal 0, g["spaceAbove"],
      "the consent sheet starts at the top of its page — all its spare room is below"
    assert_operator g["spaceBelow"], :>, 20
  end

  test "the scenario's own choice page is left alone" do
    open_player
    settle

    turn_to_choice_page

    align = page.evaluate_script(<<~JS)
      (() => {
        const scroll = document.querySelector(".preview-card.active .book-page.is-answer .book-page-scroll")
        return { justify: getComputedStyle(scroll).justifyContent,
                 kicker: getComputedStyle(scroll.querySelector(".book-page-kicker")).textAlign }
      })()
    JS

    assert_equal "normal", align["justify"],
      "the answer page holds a choice list, and a list is read down a left edge"
    assert_equal "left", align["kicker"]
  end
end
