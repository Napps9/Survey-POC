require "application_system_test_case"

# Every answer type, on every shape of screen, measured.
#
# player_type_floor_test already guards ONE of the ways a card can fail a
# respondent: type that shrinks until it can't be read. This is the rest of the
# list, and it exists because the failures it found were not subtle — they were
# whole cards that could not be answered at all, sitting in production:
#
#   - a 1280x800 laptop (and a 1366x768 one, and every window shorter than
#     about 860px) drew the flat 680px card into a 622px space with
#     `align-items: center` and `overflow: hidden`, cutting 15px off the TOP —
#     the question — and 43px off the bottom. On a scenario or consent card the
#     bottom 43px is the page-turn row, so the answer, and on a consent gate the
#     Agree button, were simply not on the screen. Nothing scrolled to them:
#     the clipping was outside the card, above the answer box's own scroller.
#   - a phone held sideways (844x390) had the same fault one level down: the
#     content panel's minimum height is bigger than the card it sits in, so 53px
#     of it hung past the card's edge — again the page-turn row, again with
#     nothing to scroll, because a card that HIDES its overflow never adds it to
#     the body's scrollHeight either.
#   - a 280px Galaxy Fold drew five rating icons in a row wider than the card,
#     so the first and last — the two ends of the scale — were cut in half and
#     could not be tapped.
#   - the swipe card's response pills, the book's page-turn chevrons and the
#     "+ Other" button were all under the 44px touch target on every phone.
#   - the scale words of a rating card sat at 11px, under the 12px floor the
#     stylesheet states for everything a respondent reads.
#
# None of that is visible to a test that asserts on markup, and none of it is
# visible on the machine it was designed on. So this drives the real player and
# measures the geometry, on the four screens that break things in different
# ways.
#
# The rule it enforces is the owner's, stated plainly: a question is never
# unreadable and an answer type is never unusable, on any device.
class AnswerTypeFitTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze

  # Each one is here because it breaks something the others don't: the Fold is
  # the narrowest real device, the SE the shortest upright phone, `sideways` a
  # phone in landscape (the least height there is), and the laptop is the size
  # that exposed the clipped card — a desktop, but a SHORT one, which is the
  # case the desktop layout had never been asked about.
  VIEWPORTS = {
    "Galaxy Fold" => [ 280, 653 ],
    "iPhone SE"   => [ 375, 553 ],
    "sideways"    => [ 844, 390 ],
    "laptop"      => [ 1280, 800 ]
  }.freeze

  TOUCH_MIN = 44      # the answer's own controls
  TEXT_MIN  = 12      # anything a respondent reads
  INPUT_MIN = 16      # under this, iOS zooms the page on focus and leaves it

  # Worst realistic content, not average: a question long enough to wrap three
  # lines on a phone, a description under it, and option labels at the top of
  # what the editor allows. A type that survives this survives a normal card.
  QUESTION = "How ready do you feel to shape the way Million Youth Media " \
             "works with young people?".freeze
  DESC     = "Think about the last few months rather than any single session.".freeze
  OPTS     = [ "Mentoring and coaching support", "Paid work experience placements",
               "Studio and equipment access", "Help getting into further education",
               "Someone to talk to about wellbeing", "Introductions to industry people" ].freeze
  SCALE    = [ "Not ready at all", "Somewhat ready", "Unsure", "Ready", "Very ready indeed" ].freeze

  def self.q(type, cid, extra = {})
    { "type" => type, "cid" => cid, "text" => QUESTION, "description" => DESC }.merge(extra)
  end

  CARDS = [
    { "type" => "welcome_card", "cid" => "w", "title" => "Welcome", "text" => "Welcome" },
    q("multiple_choice",  "c1", "options" => OPTS),
    q("select_many",      "c2", "options" => OPTS),
    q("select_one_grid",  "c3", "options" => OPTS[0, 4]),
    q("select_many_grid", "c4", "options" => OPTS),
    q("prioritise",       "c5", "options" => OPTS[0, 5]),
    q("yes_no",           "c6"),
    q("range",            "c7", "options" => SCALE),
    q("range",            "c8", "options" => SCALE, "slider_axis" => "vertical"),
    q("nps",              "c9"),
    q("rating",           "c10", "options" => [ "Poor", "Fair", "Good", "Great", "Outstanding" ]),
    # Five responses, so the strip is in its FAN shape — the tallest thing any
    # answer type draws, and the one that ran off the bottom of a short card.
    q("tap_card",         "c11",
      "options"   => [ "They drain the life out of me", "I get more done in them than alone" ],
      "responses" => [
        { "key" => "no",     "label" => "Strongly disagree", "color" => "#F5A8B0" },
        { "key" => "no2",    "label" => "Disagree",          "color" => "#FFD88A" },
        { "key" => "unsure", "label" => "Unsure",            "color" => "#D0E8FF" },
        { "key" => "yes2",   "label" => "Agree",             "color" => "#A8D5B5" },
        { "key" => "yes",    "label" => "Strongly agree",    "color" => "#01EACB" }
      ]),
    q("scenario",         "c12", "options" => OPTS[0, 4], "pages" => [
        { "id" => "p1", "text" => "You have been asked to run a session for eight young people " \
                                  "who have never used a camera before, and the studio is only " \
                                  "free for an hour." },
        { "id" => "p2", "text" => "Two of them arrive late, and one has brought a friend who is " \
                                  "not on the list." }
      ]),
    q("open_ended",       "c13"),
    q("open_ended",       "c14", "input" => "date"),
    q("open_ended",       "c15", "input" => "month"),
    q("contact_form",     "c16"),
    q("multiple_choice",  "c17", "options" => OPTS[0, 4], "allow_other" => true),
    { "type" => "consent_gate", "cid" => "c18", "text" => "Before we start", "pages" => [
        { "id" => "cp1", "text" => "Taking part is voluntary and you can stop at any time." }
      ] }
  ].freeze

  # The two answer widgets that cannot be divided: a liquid vessel with eleven
  # steps you have to be able to hit, and a stack of swipe cards with five
  # response pills that have to clear each other. Their floors — 200px and 260px
  # — are what they need to still WORK, and a phone held sideways offers the
  # answer about 240px once a three-line question has had its share. So on that
  # one screen they are taller than the panel and you scroll the answer box to
  # see all of one: every part still reachable, which this test proves either
  # way, but not all of it at once.
  #
  # Named here rather than handled by lowering the bar, so it stays a decision
  # somebody made: any OTHER control failing the same check still fails, and so
  # do these two on any other screen.
  PARTIAL_ALLOWED = {
    "sideways" => %w[nps-slider nps-control rotate-card]
  }.freeze

  # Not how you answer the card: undoing your swipes and re-opening a location
  # search take WCAG 2.5.8's 24px, not the answer's 44.
  AUXILIARY = %w[rotate-reset-btn location-search-change].freeze
  AUX_MIN   = 24

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "fit-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Fit", theme: "Th", audience_age: "adults",
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

  # One pass over the active card, in the browser, returning everything this
  # test knows how to be unhappy about. Measured rather than asserted on markup:
  # every failure in the header above was invisible to the DOM and obvious to a
  # ruler.
  PROBE = <<~JS
    (() => {
      const CONTROLS = ".pick-item, .choice-card, .rating-star, .slider-track, .slider-thumb," +
        " .rotate-card, .rotate-action, .book-chevron, .next-btn, .freeform-textarea," +
        " .freeform-date, .freeform-month, .freeform-year, .location-search-field," +
        " .contact-field, .other-cta-btn, .play-consent-agree, .play-consent-decline," +
        " .nps-slider, .nps-control, .prioritise-item, .rotate-reset-btn, .location-search-change"
      const LABELS = ".choice-label, .choice-list-label, .pick-text, .slider-label-text," +
        " .rating-label, .rotate-card-statement, .contact-field-label, .slider-readout," +
        " .freeform-counter, .contact-note"
      const TEXT = ".q-eyebrow, .q-title, .q-subtitle, .book-page-text, .book-page-kicker, " + LABELS

      // What is actually visible of an element: its rect, clipped by every
      // ancestor that hides overflow. The card's own clipping happens ABOVE the
      // answer box, so measuring against the card alone misses it.
      const visible = (el) => {
        const r = el.getBoundingClientRect()
        let box = { top: r.top, bottom: r.bottom, left: r.left, right: r.right }
        for (let p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
          const s = getComputedStyle(p)
          if (!/hidden|auto|scroll/.test(s.overflowY + s.overflowX)) continue
          const pr = p.getBoundingClientRect()
          box.top = Math.max(box.top, pr.top); box.bottom = Math.min(box.bottom, pr.bottom)
          box.left = Math.max(box.left, pr.left); box.right = Math.min(box.right, pr.right)
        }
        const seen = Math.max(0, box.bottom - box.top) * Math.max(0, box.right - box.left)
        const all  = r.width * r.height
        return all > 0 ? seen / all : 1
      }
      const shown = (el) => {
        const s = getComputedStyle(el)
        if (s.display === "none" || s.visibility === "hidden" || Number(s.opacity) === 0) return false
        const r = el.getBoundingClientRect()
        return r.width > 0 && r.height > 0
      }
      // Scroll an element into view the way a RESPONDENT can: by moving the
      // containers that actually scroll. Not scrollIntoView — that will happily
      // scroll an `overflow: hidden` box, which has no scrollbar, ignores the
      // wheel and ignores a finger. Using it here counted a control clipped off
      // the bottom of the card as reachable, which is the precise failure this
      // test was written to catch.
      const bringIntoView = (el) => {
        for (let n = el.parentElement; n && n !== document.documentElement; n = n.parentElement) {
          const s = getComputedStyle(n)
          if (!/auto|scroll/.test(s.overflowY)) continue
          if (n.scrollHeight <= n.clientHeight + 1) continue
          const er = el.getBoundingClientRect(), nr = n.getBoundingClientRect()
          n.scrollTop += (er.top + er.height / 2) - (nr.top + nr.height / 2)
        }
      }
      // A book keeps its other pages behind the current one and a swipe stack
      // keeps the cards under the top one. They are in the DOM and they are the
      // wrong size on purpose; nothing can touch them, so nothing measures them.
      const touchable = (el) => {
        const r = el.getBoundingClientRect()
        const x = r.left + r.width / 2, y = r.top + r.height / 2
        if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) return true
        const hit = document.elementFromPoint(x, y)
        return !hit || el.contains(hit) || hit.contains(el)
      }

      const card = document.querySelector("[data-player-target='card'].active")
      if (!card) return null
      const out = { type: card.dataset.cardType, problems: [] }
      const say = (kind, what, detail) => out.problems.push({ kind, what, detail })

      // 1. The question is entirely on the card.
      for (const sel of [".q-eyebrow", ".q-title", ".q-subtitle"]) {
        const el = card.querySelector(sel)
        if (!el || !shown(el) || !el.textContent.trim()) continue
        const ratio = visible(el)
        if (ratio < 0.995) say("question-clipped", sel, Math.round((1 - ratio) * 100) + "% off the card")
      }

      // 2. Every control is reachable, and whole when they get to it.
      //
      // The cut-off check does NOT ask whether a tap would land on the control:
      // a card sitting behind the top of a swipe stack is covered but perfectly
      // whole, while a chevron clipped off the bottom of the card is uncovered
      // and gone. Hit-testing conflates them, and it conflates them in the
      // dangerous direction — it was quietly excusing exactly the clipped
      // controls this test exists to catch. Geometry answers "is it there";
      // hit-testing only decides which controls are worth MEASURING as targets.
      const live = []
      for (const el of [...card.querySelectorAll(CONTROLS)].filter(shown)) {
        const restore = []
        for (let n = el.parentElement; n && n !== document.documentElement; n = n.parentElement) {
          restore.push([ n, n.scrollTop ])
        }
        bringIntoView(el)
        const ratio = visible(el)
        if (ratio < 0.9) {
          say("control-cut-off", (el.className || el.tagName).toString().split(" ")[0],
              Math.round(ratio * 100) + "% visible even scrolled to")
        }
        if (touchable(el)) live.push(el)
        for (const [ n, top ] of restore) n.scrollTop = top
      }
      if (!live.length && card.dataset.cardType !== "welcome_card") {
        say("no-controls", card.dataset.cardType, "nothing to answer with")
      }

      // 3. Nothing spills sideways out of the panel.
      const panel = card.querySelector(".split-right")
      if (panel && panel.scrollWidth > panel.clientWidth + 1) {
        say("sideways-overflow", "split-right", panel.scrollWidth + " > " + panel.clientWidth)
      }

      // 4. Touch targets.
      if (window.__touch) {
        for (const el of live) {
          // The drag surfaces are gestures, not targets: you aim at the whole
          // thing, and it is always far bigger than a finger.
          if (el.matches(".slider-track, .rotate-card, .nps-slider, .nps-control, .prioritise-item")) continue
          const r = el.getBoundingClientRect()
          say("target", (el.className || el.tagName).toString().split(" ")[0],
              Math.round(Math.min(r.width, r.height)))
        }
      }

      // 5. No answer word is broken down the middle, and nothing is under the
      //    reading floor.
      const probe = document.createElement("span")
      probe.style.cssText = "position:absolute;visibility:hidden;white-space:nowrap;top:0;left:0"
      document.body.appendChild(probe)
      for (const el of [...card.querySelectorAll(LABELS)].filter(shown)) {
        const text = el.textContent.trim()
        if (!text) continue
        const s = getComputedStyle(el)
        probe.style.font = s.fontStyle + " " + s.fontWeight + " " + s.fontSize + "/" +
                           s.lineHeight + " " + s.fontFamily
        probe.style.letterSpacing = s.letterSpacing
        const room = el.clientWidth - parseFloat(s.paddingLeft) - parseFloat(s.paddingRight)
        for (const word of text.split(/\\s+/)) {
          probe.textContent = word
          if (probe.getBoundingClientRect().width > room + 0.5) {
            say("word-broken", (el.className || el.tagName).toString().split(" ")[0],
                JSON.stringify(word) + " in " + Math.round(room) + "px")
            break
          }
        }
      }
      probe.remove()
      for (const el of [...card.querySelectorAll(TEXT)].filter(shown)) {
        if (!el.textContent.trim()) continue
        const px = parseFloat(getComputedStyle(el).fontSize)
        say("text-size", (el.className || el.tagName).toString().split(" ")[0], px)
      }
      for (const el of [...card.querySelectorAll("textarea, input[type=text], input[type=email], input[type=date]")].filter(shown)) {
        say("input-size", (el.className || el.tagName).toString().split(" ")[0],
            parseFloat(getComputedStyle(el).fontSize))
      }
      return out
    })()
  JS

  def open_at(width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  # The card entry animation translates and scales the whole card, so anything
  # measured while it runs is geometry no respondent ever sees.
  def settle
    page.has_no_css?(".preview-card.active.is-entering", wait: 2)
    sleep 0.25
  end

  # Walk the deck, collecting every complaint. A book card doesn't advance on
  # Next until its pages have been turned, so this pages through them; that is
  # also what puts the consent gate's Agree button on screen to be measured.
  def sweep(name, touch:)
    page.execute_script("window.__touch = #{touch}")
    problems = []
    seen = []
    24.times do
      settle
      result = page.evaluate_script(PROBE)
      break unless result
      seen << result["type"]
      result["problems"].each { |p| problems << p.merge("type" => result["type"], "viewport" => name) }
      break unless advance
    end
    [ problems, seen ]
  end

  def advance
    page.execute_script(<<~JS)
      (() => {
        const card = document.querySelector("[data-player-target='card'].active")
        const chevron = card && card.querySelector(".book-nav-row .book-chevron:last-child")
        if (chevron && !chevron.disabled) chevron.click()
        const agree = card && card.querySelector(".play-consent-agree")
        if (agree && agree.offsetParent) agree.click()
        const next = document.querySelector(".preview-btn-next")
        if (next && getComputedStyle(next).display !== "none") next.click()
      })()
    JS
    true
  end

  # ── The four assertions ───────────────────────────────────────────────────

  VIEWPORTS.each do |name, (w, h)|
    test "every answer type is answerable at #{name} (#{w}x#{h})" do
      open_at(w, h)
      problems, seen = sweep(name, touch: w < 900)

      assert_includes seen, "tap_card", "the sweep never reached the end of the deck (saw: #{seen.uniq.inspect})"
      assert_includes seen, "consent_gate", "the sweep stopped before the last card"

      clipped = problems.select { |p| p["kind"] == "question-clipped" }
      assert_empty clipped.map { |p| "#{p['type']}: #{p['what']} #{p['detail']}" },
        "the question is the point of the card and must never be the thing that falls off it"

      cut = problems.select { |p| p["kind"] == "control-cut-off" }
                    .reject { |p| Array(PARTIAL_ALLOWED[name]).include?(p["what"]) }
      assert_empty cut.map { |p| "#{p['type']}: #{p['what']} #{p['detail']}" },
        "an answer control a respondent cannot see is an answer they cannot give"

      assert_empty problems.select { |p| p["kind"] == "no-controls" }.map { |p| p["type"] },
        "a question card with nothing to answer it with"

      assert_empty problems.select { |p| p["kind"] == "sideways-overflow" }
                           .map { |p| "#{p['type']}: #{p['detail']}" },
        "the panel is clipping its own contents sideways"

      assert_empty problems.select { |p| p["kind"] == "word-broken" }
                           .map { |p| "#{p['type']}: #{p['what']} #{p['detail']}" },
        "an answer label broken mid-word is an answer label nobody can read at a glance"
    end
  end

  test "nothing a respondent reads is under the floor, on any of these screens" do
    VIEWPORTS.each do |name, (w, h)|
      open_at(w, h)
      problems, = sweep(name, touch: w < 900)

      small = problems.select { |p| p["kind"] == "text-size" && p["detail"] < TEXT_MIN }
      assert_empty small.map { |p| "#{name}/#{p['type']}: #{p['what']} #{p['detail']}px" },
        "respondent-facing text under #{TEXT_MIN}px"

      tiny = problems.select { |p| p["kind"] == "input-size" && p["detail"] < INPUT_MIN }
      assert_empty tiny.map { |p| "#{name}/#{p['type']}: #{p['what']} #{p['detail']}px" },
        "under #{INPUT_MIN}px iOS zooms the page on focus and never zooms back"
    end
  end

  test "every control a thumb has to hit is big enough to hit" do
    VIEWPORTS.select { |_n, (w, _h)| w < 900 }.each do |name, (w, h)|
      open_at(w, h)
      problems, = sweep(name, touch: true)

      targets = problems.select { |p| p["kind"] == "target" }
      small = targets.reject do |p|
        floor = AUXILIARY.include?(p["what"]) ? AUX_MIN : TOUCH_MIN
        p["detail"] >= floor - 0.5
      end
      assert_empty small.map { |p| "#{name}/#{p['type']}: #{p['what']} #{p['detail']}px" },
        "answer controls take #{TOUCH_MIN}px, auxiliary ones #{AUX_MIN}px (WCAG 2.5.8)"
    end
  end
end
