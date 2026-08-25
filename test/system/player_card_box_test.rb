require "application_system_test_case"

# Four device faults from one iPhone run, three of which share a cause.
#
# THE CAUSE. --play-card-h is the token every mobile tier takes its hero and
# its answer panel from, and its CSS definition — 100svh less the footer — is
# an estimate of the deck's box rather than a measurement of it. What it
# cannot see is anything stacked ABOVE the card inside .preview-overlay: an
# org masthead, and on a notched iPhone the strip the safe area holds open.
# The Test Mode banner was the third, and when these tests were written the
# owner's screenshots were all Test Mode on a phone with a dynamic island —
# two at once, and the card ~90px shorter than the token believed. Test Mode
# is a ring now (.play-test-frame, out of flow, see test_mode_frame_test), so
# that particular 31px is gone. The mechanism is not: the INSET below stands
# for ANY element between the top of the overlay and the deck, and the
# measurement is what makes all of them harmless. The hero is `flex: 0 0 auto` at 45% of the WRONG number, and
# .split-right's min-height claims 55% of it on top, so the panel overflowed
# the card and its bottom was cut.
#
# What falls off the bottom is usually padding. On a scenario it is
# .book-nav-row — the two chevrons that are the only way to turn a page, with
# no swipe fallback — which is why the report was "its unclear in the scenario
# question type how to go to the next one".
#
# The banner is not reproducible here (Test Mode needs its own token and the
# safe area needs a real device), so these tests INJECT a strip of the same
# height above the card. That is the mechanism, not a stand-in for it: any
# element between the top of the overlay and the deck does this.
class PlayerCardBoxTest < ApplicationSystemTestCase
  # A dynamic island's worth. The exact number is not load-bearing — what is
  # load-bearing is that the card gets shorter and the token has to notice.
  INSET = 55

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "pcb-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Box", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      compare_note: "See how your answers sit against everyone else.",
      cards: [
        { "type" => "welcome_card", "cid" => "w", "image" => "/nope.jpg", "text" => "Every way Verto can ask a question",
          "description" => "Thirteen answer types, one deck, about three minutes." },
        { "type" => "select_many_grid", "cid" => "g", "image" => "/nope.jpg", "text" => "What keeps you from playing more often?",
          "options" => [ "Nowhere nearby", "No one to go with", "Injury or health",
                         "Not confident", "Costs too much", "No time" ] },
        { "type" => "scenario", "cid" => "sc", "image" => "/nope.jpg", "text" => "What would you do?",
          "pages" => [ { "id" => "p1", "text" => "A card goes through your door. The club at the " \
                                                 "end of your road is running a free session on " \
                                                 "Saturday morning." },
                       { "id" => "p2", "text" => "You have nothing else on that morning." } ],
          "options" => [ "I'd go", "I'd think about it", "Not for me" ] },
        { "type" => "consent_gate", "cid" => "cg", "image" => "/nope.jpg",
          "pages" => [ { "id" => "c1", "text" => "We will keep your answers for two years." } ] },
        { "type" => "range", "cid" => "r", "image" => "/nope.jpg", "text" => "How much does sport belong in your week?",
          "options" => [ "Not at all", "A little", "Some", "A lot", "Totally" ] }
      ]
    )
    @survey.update_columns(
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      show_results_comparison: true, tokenisation_enabled: true, leaderboard_enabled: true,
      token_types: [ { "icon" => "🏅", "name" => "Play Points" } ]
    )
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  # A phone that is short enough for the panel to be under real pressure. An
  # iPhone 15 with Safari's toolbar up is 393x768, which is what the owner's
  # screenshots were taken on.
  def open_player(width: 393, height: 768, inset: 0)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    assert_selector ".preview-card.active", wait: 5
    add_inset(inset) if inset.positive?
    sleep 0.4
  end

  def add_inset(px)
    page.execute_script(<<~JS)
      const ov = document.querySelector(".preview-overlay")
      const strip = document.createElement("div")
      strip.style.cssText = "height:#{px.to_i}px;flex:0 0 auto;background:#272D4A"
      ov.insertBefore(strip, ov.firstChild)
    JS
    sleep 0.4
  end

  def advance_to(card_type)
    12.times do
      break if page.evaluate_script("document.querySelector('.preview-card.active')?.dataset.cardType") == card_type

      page.execute_script(<<~JS)
        const c = document.querySelector(".preview-card.active")
        const pick = c.querySelector(".choice-card, .choice-list-item")
        if (pick) pick.click()
      JS
      sleep 0.2
      # A book card has to be turned to its last page before Next will take it.
      4.times do
        moved = page.evaluate_script(<<~JS)
          (() => { const c = document.querySelector(".preview-card.active")
            const chevrons = c.querySelectorAll(".book-chevron")
            const nx = chevrons[chevrons.length - 1]
            if (!nx || nx.disabled) return false
            nx.click(); return true })()
        JS
        break unless moved

        sleep 0.25
      end
      page.execute_script(<<~JS)
        const c = document.querySelector(".preview-card.active")
        const pick = c.querySelector(".choice-list-item, .choice-card")
        if (pick) pick.click()
        c.querySelector(".play-consent-agree")?.click()
        document.querySelector(".preview-btn-next")?.click()
      JS
      sleep 0.7
    end
    assert_equal card_type,
                 page.evaluate_script("document.querySelector('.preview-card.active')?.dataset.cardType"),
                 "never reached a #{card_type} card"
  end

  def box_report
    page.evaluate_script(<<~JS)
      (() => {
        const ov = document.querySelector(".preview-overlay")
        const body = document.querySelector(".preview-body")
        const card = document.querySelector(".preview-card.active")
        const sr = card.querySelector(".split-right")
        const box = card.querySelector(".split-right > .mt-2")
        const cs = box ? getComputedStyle(box) : null
        const nav = card.querySelector(".book-nav-row")
        const bodyB = body.getBoundingClientRect().bottom
        return {
          type: card.dataset.cardType,
          cardHToken: getComputedStyle(ov).getPropertyValue("--play-card-h").trim(),
          bodyH: Math.round(body.clientHeight),
          heroH: (() => { const h = card.querySelector(".split-left")
            return h ? Math.round(h.getBoundingClientRect().height) : null })(),
          panelOverBody: Math.round(sr.getBoundingClientRect().bottom - bodyB),
          navOverBody: nav ? Math.round(nav.getBoundingClientRect().bottom - bodyB) : null,
          overflowY: cs && cs.overflowY,
          over: box ? box.scrollHeight - box.clientHeight : null,
          scrollable: box ? box.classList.contains("is-scrollable") : null,
          mask: cs ? (cs.webkitMaskImage || cs.maskImage) : null,
          scrollbar: cs && cs.scrollbarWidth
        }
      })()
    JS
  end

  # ── D0: the token has to be the card, not an estimate of it ───────────────

  test "the card-height token tracks the box the card is actually in" do
    open_player
    before = box_report

    assert_match(/\A\d+(\.\d+)?px\z/, before["cardHToken"],
                 "--play-card-h is still the CSS estimate (#{before['cardHToken']}). It has to be " \
                 "MEASURED: the calc is 100svh less the footer, which cannot see anything stacked " \
                 "above the card inside the overlay, and the Test Mode banner and a notched " \
                 "phone's safe-area strip are both exactly that.")
    assert_in_delta before["bodyH"], before["cardHToken"].to_f, 1.5,
                    "the token says #{before['cardHToken']} and .preview-body — the box the card " \
                    "lives in — is #{before['bodyH']}px"

    add_inset(INSET)
    after = box_report

    assert_in_delta before["bodyH"] - INSET, after["bodyH"], 1.5,
                    "the inset did not shorten the card box, so this test is not testing anything"
    assert_in_delta after["bodyH"], after["cardHToken"].to_f, 1.5,
                    "a #{INSET}px strip went in above the card and the token did not follow " \
                    "(#{after['cardHToken']} against a #{after['bodyH']}px box). The " \
                    "ResizeObserver on .preview-body is what makes rotation, the iOS toolbar and " \
                    "the keyboard land correctly too."
  end

  test "the answer panel stays inside the card when something sits above it" do
    open_player(inset: INSET)
    r = box_report

    assert_operator r["panelOverBody"], :<=, 1,
                    "the answer panel hangs #{r['panelOverBody']}px below the card. Its " \
                    "min-height is --play-right-min, 55% of --play-card-h — so an over-stated " \
                    "token doesn't just misplace the split, it pushes the panel out of the card " \
                    "and .preview-body cuts whatever is at the bottom of it."
    assert_in_delta 0.45, r["heroH"].to_f / r["bodyH"], 0.02,
                    "the hero is #{r['heroH']} of a #{r['bodyH']}px card, which is " \
                    "#{(100.0 * r['heroH'] / r['bodyH']).round(1)}% and not the 45% the owner " \
                    "signed off. A fixed height taken from an over-stated token is a bigger " \
                    "share of the card that actually exists."
  end

  # ── D1: the welcome card's pills ──────────────────────────────────────────

  test "the welcome card's pills scroll rather than being cut" do
    open_player(inset: INSET)
    r = box_report

    assert_equal "welcome_card", r["type"]
    assert_equal "auto", r["overflowY"],
                 "the welcome card's box has no scroll path. .welcome-intake was never added to " \
                 "the .mt-2 scroller allowlist — it is a list of ANSWER widgets and the welcome " \
                 "card has no answer — so the compare promise, the points note, the token pills " \
                 "and the leaderboard tease overflow .split-right and its overflow: hidden cuts " \
                 "the last one in half. 'i cant read or scroll the boxees on the first card.'"
    assert_operator r["over"], :>, 0,
                    "the box reports nothing to scroll, so either the content now fits (make the " \
                    "inset bigger and check again) or min-height: 0 is missing and the box is " \
                    "overflowing the PANEL instead of its own content — which is the failure " \
                    "mode that made this invisible to _fitCard for so long."
    assert r["scrollable"], "there is #{r['over']}px below the fold and no cue saying so"
  end

  # ── D2: the cue must not paint on the artwork, and must not drift ─────────

  test "a scrolling answer is cued by fading its own edge, not by a sticky overlay" do
    open_player(inset: INSET)
    advance_to "select_many_grid"
    r = box_report

    assert r["scrollable"], "the six-tile grid is not scrolling; this test needs it to"
    assert_includes r["mask"].to_s, "gradient",
                    "the scroll cue is not a mask on the box. It used to be a sticky child filled " \
                    "with linear-gradient(transparent, #fff): white, which is invisible over a " \
                    "list of white rows and a bar across the artwork over full-bleed tiles " \
                    "('scroll line leaves a blur effect on the options'), and sticky, which on " \
                    "iOS does not reposition during a momentum fling — the owner's photo caught " \
                    "it stranded 63px up, in the middle of a tile."

    stickies = page.evaluate_script(<<~JS)
      (() => {
        const box = document.querySelector(".preview-card.active .split-right > .mt-2")
        const out = []
        for (const el of [ box, ...box.querySelectorAll("*") ]) {
          const a = getComputedStyle(el, "::after")
          if (a.position === "sticky" && /gradient/.test(a.backgroundImage)) out.push(el.className)
        }
        return out
      })()
    JS
    assert_empty stickies,
                 "a sticky gradient ::after is back inside the scroller (#{stickies.inspect}). " \
                 "Anything painted from inside the scrolling content can be left behind by an " \
                 "iOS fling; the cue has to belong to the box."
  end

  test "the player's answer scroller shows no scrollbar" do
    open_player(inset: INSET)
    advance_to "select_many_grid"

    assert_equal "none", box_report["scrollbar"],
                 "the bare scrollbar is back on the answer. The owner has objected to it twice, " \
                 "and with a fade that actually reads there is nothing left for it to be the " \
                 "only signal of — same call .book-page-scroll already made. Desktop keeps its " \
                 "thin bar and is not covered by this."
  end

  # ── D3: the scenario ──────────────────────────────────────────────────────

  test "a scenario's page-turn chevrons stay inside the card" do
    open_player(inset: INSET)
    advance_to "scenario"
    r = box_report

    assert_operator r["navOverBody"], :<=, 0,
                    "the page-turn chevrons are #{r['navOverBody']}px below the bottom of the " \
                    "card. .book-nav-row is the last thing in the book column and the first " \
                    "thing off the bottom when the panel overshoots — and a scenario has no " \
                    "swipe fallback, so a respondent whose chevrons are cut has no way forward " \
                    "at all. The owner's screenshot shows the dots half-cut and no chevrons."
    assert_selector ".preview-card.active .book-chevron", minimum: 2
  end

  test "a scenario centres its narrative and a consent sheet does not" do
    open_player
    advance_to "scenario"
    story = page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector(".preview-card.active")
        return { justify: getComputedStyle(c.querySelector(".book-page-scroll")).justifyContent,
                 align: getComputedStyle(c.querySelector(".book-page-text")).textAlign } })()
    JS

    assert_equal "safe center", story["justify"],
                 "the scenario's page no longer centres its story vertically — a few lines sat " \
                 "in the top-left of a 314px page with the rest empty. safe, not plain center: " \
                 "the page scrolls, and plain centring puts a long page's overflow above scroll " \
                 "position zero where nothing can reach it."
    assert_equal "center", story["align"], "the scenario's story is not centred horizontally"

    advance_to "consent_gate"
    sheet = page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector(".preview-card.active")
        const t = c.querySelector(".book-page-text")
        return t ? getComputedStyle(t).textAlign : null })()
    JS

    assert_equal "left", sheet,
                 "consent_gate renders the same book and has been centred along with it. A story " \
                 "is a few lines and reads better centred; an information sheet is a wall of " \
                 "terms and reads worse. The scenario's rules are scoped to .book-wrap--scenario " \
                 "for exactly this."
  end

  # ── D4: the slider's edge pad ─────────────────────────────────────────────

  test "the slider's edge pad is claimed by the page, not left to the browser" do
    open_player
    advance_to "range"
    ta = page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector(".preview-card.active")
        return { wrap: getComputedStyle(c.querySelector(".slider-track-wrap")).touchAction,
                 track: getComputedStyle(c.querySelector(".slider-track")).touchAction } })()
    JS

    assert_equal "none", ta["track"], "the track's own touch-action is gone"
    assert_equal "none", ta["wrap"],
                 "the 32px pad either side of the track is back at touch-action: auto. That pad " \
                 "is what keeps the thumb out of the OS back-swipe strip, and leaving it " \
                 "unclaimed only moves the problem: a finger reaching for the thumb at an " \
                 "extreme lands on a strip the page does not handle, iOS takes the gesture, and " \
                 "the whole web view peels sideways. 'when I slide the scale the screen moves.'"
  end
end
