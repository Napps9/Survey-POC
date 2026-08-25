require "application_system_test_case"

# The header is a promise: 45% of the screen on every card that can carry one,
# and the answer scrolls if it must. It used to be a negotiation — _fitCard
# priced the answer and bought the picture back only while it stayed free — so
# the same Verto rendered differently on two phones depending on how many
# options a creator had typed.
#
# There are exactly four ways the promise is allowed to be broken, and this
# file is mostly about them, because a guarantee is only worth what its
# exceptions are:
#
#   tap matrix — its card stack cannot shrink
#   NPS        — its scale cannot shrink either
#   prioritise — its rows are drag targets (touch-action: none), so a list
#                past the fold cannot even be scrolled to; an option off the
#                bottom is unreachable, not merely hidden
#   typing     — a focused text field takes the hero's room for the keyboard
#
# The last is the one that would quietly un-fix something already signed off.
class HeroPromiseTest < ApplicationSystemTestCase
  PHONE   = [ 393, 852 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  # Twelve image options on a phone is the case the shed ladder was built for:
  # no arrangement of them fits, so under the old rules the card gave up its
  # tiles and then its hero.
  TWELVE = (1..12).map { |i| "Topic number #{i}" }.freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "promise-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Promise", theme: "T", audience_age: "all",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Hi" },
                                     { "type" => "select_many_grid", "cid" => "g", "image" => "/nope.jpg",
                                       "text" => "Which of these?", "options" => TWELVE },
                                     { "type" => "open_ended", "cid" => "o", "image" => "/nope.jpg",
                                       "text" => "Tell us more" },
                                     { "type" => "tap_card", "cid" => "t", "image" => "/nope.jpg",
                                       "text" => "How did it land?",
                                       "options" => [ "It was worth it", "The dates worked" ] },
                                     { "type" => "nps", "cid" => "n", "image" => "/nope.jpg",
                                       "text" => "How likely?" },
                                     { "type" => "prioritise", "cid" => "p", "image" => "/nope.jpg",
                                       "text" => "Drag these into the order that matters to you.",
                                       "options" => [ "Cheaper sessions", "More times to choose",
                                                      "Friendlier clubs", "Better facilities",
                                                      "Closer to home" ] }
                                   ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_at(card)
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    card.times { click_button "Next"; sleep 0.35 }
    sleep 0.4
  end

  # The hero's height as a share of the card, and whether it is drawn at all.
  def hero
    page.evaluate_script(<<~JS)
      (() => {
        const c = document.querySelector(".preview-card.active")
        const sl = c.querySelector(".split-left")
        const sc = c.querySelector(".split-card")
        const d = sl && getComputedStyle(sl).display
        if (!sl || d === "none" || d === "contents") return { type: c.dataset.cardType, shown: false }
        return { type: c.dataset.cardType, shown: true,
                 share: +(sl.getBoundingClientRect().height / sc.getBoundingClientRect().height).toFixed(3) }
      })()
    JS
  end

  test "a twelve-option grid keeps its header instead of shedding it" do
    open_at(1)
    h = hero

    assert_equal "select_many_grid", h["type"]
    assert h["shown"], "the header went. It is a promise now — a long list does not get to revoke it."
    assert_operator h["share"], :>, 0.38,
                    "the header is #{(h['share'] * 100).round(1)}% of the card. Measured at 27.9% " \
                    "with the ladder retired but the strip still shrinkable, so a number down " \
                    "there means flex is squeezing it again rather than the answer scrolling."
  end

  test "a card whose answer fits keeps its header too" do
    open_at(2)
    h = hero

    assert_equal "open_ended", h["type"]
    assert h["shown"]
    assert_operator h["share"], :>, 0.38
  end

  # ── The four exceptions ──

  test "the tap matrix has no header, because its stack cannot shrink" do
    open_at(3)
    h = hero

    assert_equal "tap_card", h["type"]
    assert_not h["shown"],
               "the tap matrix was given a header. Its card stack grows to fill the panel and " \
               "has nowhere to shrink to, which is why it is one of the excluded types."
  end

  test "NPS has no header, for the same reason" do
    open_at(4)
    h = hero

    assert_equal "nps", h["type"]
    assert_not h["shown"], "NPS was given a header; its scale cannot give the room back."
  end

  # Prioritise is the exception with teeth. The other two merely look wrong
  # when squeezed; this one stops working. The whole row is the drag handle,
  # so .prioritise-item is touch-action: none — a finger cannot scroll the
  # list, only drag a row. An option below the fold therefore cannot be
  # reached at all, and a ranking submitted without it ranks the wrong set.
  test "prioritise has no header, because a row it cannot reach is a row it cannot rank" do
    open_at(5)
    h = hero

    assert_equal "prioritise", h["type"]
    assert_not h["shown"],
               "prioritise was given a header. That is 45% of the card taken from a list whose " \
               "rows cannot be scrolled to — the last options end up behind the floating " \
               "controls with no gesture that reaches them."
  end

  # Dropping the header must not drop what was PARKED INSIDE it.
  #
  # .panel-progress is markup inside .split-left, so `display: none` on the
  # excepted types took the progress bar out with the picture — measured across
  # all eight card types on a phone, those were the only ones with no bar at all.
  # A respondent lost their sense of how far through they were on exactly the
  # cards that take longest to answer.
  #
  # The fix is `display: contents`, which is a narrow line to walk: too far and
  # the hero comes back (the tests above catch that), not far enough and the
  # bar stays gone (this one does). Both halves have to hold at once, which is
  # why they are neighbours in this file.
  [ [ 3, "tap_card" ], [ 4, "nps" ], [ 5, "prioritise" ] ].each do |index, type|
    test "#{type} keeps its progress bar even though it has no header" do
      open_at(index)
      bar = page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector(".preview-card.active")
          const el   = card.querySelector(".panel-progress")
          const fill = card.querySelector(".panel-progress-fill")
          if (!el) return { present: false }
          const r = el.getBoundingClientRect()
          return { present: true,
                   laidOut: el.getClientRects().length > 0 && r.width > 1,
                   width: Math.round(r.width),
                   fill: fill ? getComputedStyle(fill).backgroundColor : null }
        })()
      JS

      assert bar["present"], "#{type} has no .panel-progress in the DOM at all"
      assert bar["laidOut"],
             "#{type}'s progress bar is in the tree but not drawn (#{bar['width']}px wide). " \
             "The bar lives inside .split-left; hiding that panel with `display: none` " \
             "hides the bar with it, and `contents` is what keeps the children while " \
             "dropping the box."
      assert_equal "rgb(1, 234, 203)", bar["fill"],
                   "#{type}'s progress bar is drawn but not in the brand colour"
    end
  end

  # The exception that matters most, because breaking it would silently undo
  # the keyboard work rather than look wrong on a screenshot: a focused text
  # field still takes the hero's room. _watchTyping owns hero-off now that
  # _fitCard does not, and the restore on blur is its pair — a hero that never
  # comes back is the failure mode this half is really guarding.
  test "typing still takes the header, and gives it back afterwards" do
    open_at(2)
    assert hero["shown"], "precondition: the free-text card should start with its header"

    find(".preview-card.active .freeform-textarea").click
    sleep 0.5
    assert_not hero["shown"],
               "the header stayed up while typing. That is ~45% of the screen the keyboard and " \
               "the field needed."

    # Blur by clicking the question, which is not a text control.
    find(".preview-card.active .q-title").click
    sleep 0.6
    assert hero["shown"],
           "the header never came back after typing. _fitCard used to remove hero-off as a side " \
           "effect of recomputing the ladder; with the ladder gone the restore has to be explicit, " \
           "and without it the hero stays off for the rest of the deck."
  end
end
