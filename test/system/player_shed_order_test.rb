require "application_system_test_case"

# What the player guarantees when it runs out of room — and it is a different
# promise now, which is why this file's name is the last thing left of the shed
# order.
#
# There used to be a ladder. _fitCard priced the undecorated answer as a debt
# and bought back the option artwork and then the hero, each only while it
# stayed free, so a card that could not afford its picture gave it up. That
# made the same Verto render differently on two phones, which is what got
# reported: "everything else can have a header I think — even long lists,
# because players should know to scroll."
#
# So the trade is off, and BOTH rungs went. What the ladder was protecting is
# still protected, just not out of the pictures any more:
#
#   the header holds its share    — on every card that can carry one
#   every option survives         — the tiles keep their artwork too
#   Back and Next stay reachable  — never negotiable, at any size
#   whatever is left over scrolls — with the "more below" cue to say so
#
# The three tests that asserted the ladder's rungs are gone. They were not
# wrong, they were about a mechanism that no longer exists — and the priority
# they encoded is asserted directly below instead, which is what they were
# really for.
#
# Two card types still hide their strip, and always did it in CSS rather than
# through the ladder: the tap matrix and NPS, whose answers cannot shrink.
class PlayerShedOrderTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze
  ROOMY   = [ 1024, 1290 ].freeze  # iPad Pro upright — everything fits
  TIGHT   = [ 844,  390 ].freeze   # a phone turned sideways
  PHONE   = [ 393,  852 ].freeze   # iPhone 15 upright — where the header promise is measured

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

  # What the card is actually showing, now that there are no rungs to count.
  def card_state
    page.evaluate_script(<<~JS)
      (() => {
        const c = document.querySelector(".preview-card.active")
        const box = c.querySelector(".split-right > .mt-2")
        const sl = c.querySelector(".split-left")
        const sc = c.querySelector(".split-card")
        const shown = sl && getComputedStyle(sl).display !== "none" &&
                            getComputedStyle(sl).display !== "contents"
        return {
          heroShown: !!shown,
          heroPx: shown ? +sl.getBoundingClientRect().height.toFixed(1) : 0,
          cardPx: +sc.getBoundingClientRect().height.toFixed(1),
          options: c.querySelectorAll(".choice-card, .choice-list-item").length,
          tiles: c.querySelectorAll(".choice-card-bg").length,
          scrolls: box ? box.scrollHeight - box.clientHeight > 1 : false,
          cue: box ? box.classList.contains("is-scrollable") : false
        }
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

  test "a card that fits shows everything" do
    open_at(*ROOMY)
    st = card_state

    assert st["heroShown"], "there was room for the picture — it should be there"
    assert_equal st["options"], st["tiles"],
                 "every option should still be carrying its artwork"
    assert_not st["scrolls"], "this card fits; nothing should be scrolling"
  end

  # The case the ladder was built for, and the one the new promise is really
  # about: twelve image tiles cannot fit a phone, and they no longer have to.
  # Measured before this change the same card shed to 27.9% of the screen on an
  # iPhone 15 and 23.5% on an SE; the tiles went too.
  test "twelve options keep their header and their artwork, and scroll" do
    open_at(*PHONE, card: 2)
    st = card_state

    assert st["heroShown"], "the header is a promise now — a long list does not get to revoke it"
    assert_equal 12, st["options"], "no option may be dropped, whatever else happens"
    assert_equal 12, st["tiles"],   "the option artwork stays too — scrolling is the answer, not shedding"
    assert st["scrolls"], "twelve tiles cannot fit a phone; this should be scrolling"
    assert st["cue"],
           "it scrolls but is not saying so — is-scrollable draws the 'more below' fade, and it " \
           "matters more now than it did when the card would shed until it fitted"
  end

  # The header's share is the point, not merely its presence: a hero squeezed
  # to a sliver is the same failure the ladder used to cause outright. The
  # strip is flex-shrink 0 for exactly this reason — retiring the ladder alone
  # left the answer panel quietly squeezing it instead.
  test "the header holds its share even against a long answer" do
    open_at(*PHONE, card: 2)
    st = card_state

    share = st["heroPx"] / st["cardPx"]
    assert_operator share, :>, 0.38,
                    "the header is #{(share * 100).round(1)}% of the card against a twelve-option " \
                    "list. It is meant to hold ~45% (--play-hero-h against --play-right-min); " \
                    "anything much under that means something is shrinking it again."
  end

  # A sideways phone is the tightest real case — and the one where shedding
  # used to be most aggressive.
  test "a sideways phone keeps the options and scrolls rather than stripping the card" do
    open_at(*TIGHT, card: 2)
    st = card_state

    assert_equal 12, st["options"], "every option survives, at every size"
    assert_equal 12, st["tiles"],   "and so does its artwork"
  end

  # Never negotiable, and the one assertion in this file that predates the
  # ladder, outlives it, and did not need rewriting.
  [ ROOMY, TIGHT, [ 375, 553 ], [ 280, 653 ] ].each do |w, h|
    test "Back and Next stay on screen and usable at #{w}x#{h}" do
      open_at(w, h, card: 2)
      st = card_state

      assert controls_usable?,
             "the footer is never on the list of things to give up (card #{st['cardPx']}px, " \
             "hero #{st['heroPx']}px, #{st['scrolls'] ? 'scrolling' : 'not scrolling'})"
    end
  end

  # Nothing is shed any more, so there is nothing to come back — but the card
  # must still re-lay-out on rotation rather than keeping the narrow geometry.
  test "the card re-lays-out when the room changes" do
    open_at(*TIGHT, card: 2)
    sideways = card_state

    page.driver.browser.resize(width: ROOMY[0], height: ROOMY[1])
    sleep 0.5
    roomy = card_state

    assert_equal 12, sideways["options"]
    assert_equal 12, roomy["options"]
    assert_operator roomy["cardPx"], :>, sideways["cardPx"],
                    "the card did not grow into the taller viewport — it is still laid out for " \
                    "the old one."
  end
end
