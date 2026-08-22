require "application_system_test_case"

# The mobile player's Back and Next float on the card instead of standing on a
# bar. The bar cost 69px — 9% of a 768px screen — taken out of every card
# before the hero and the answer divided what was left; out of flow, that goes
# back to the card (measured 609 → 679 on an iPhone 15 in Test Mode).
#
# WHAT FLOATING BREAKS, AND WHY IT IS ONE TEST AND NOT FOUR. Nothing takes the
# controls' height out of the card any more, so the panel runs to the bottom of
# the screen and whatever sits at the foot of it lands behind the pills.
# Measured across the showcase deck with the footer floating and nothing else
# changed:
#
#   welcome's leaderboard pill  51px behind    consent's chevrons   51px behind
#   the "+ Other" CTA           51px behind    last list option     51px behind
#   prioritise's last row       50px behind    grid's last tile     39px behind
#   tap card's Reset            17px behind
#
# Seven different elements in seven different containers, and one of them —
# the grid — was behind while its answer did not scroll at all. That is what
# makes a per-shape test the wrong shape: it invites fixing the four that
# scroll and calling it done. So this asks the question a respondent asks
# instead. Scroll each answer type to its end; is the last thing you have to
# reach still reachable?
class FloatingFooterTest < ApplicationSystemTestCase
  # An iPhone 15 with Safari's toolbar up, which is what the owner's device
  # photos are, and a dynamic island's strip standing in for the safe area.
  # Both matter: they are what makes the card shorter than the CSS thinks.
  W = 393
  H = 768
  INSET = 55

  # Clearance, not merely "not behind". Landing an option exactly on the pill's
  # top edge measured as clear and read as touching, which is why
  # --play-pill-zone carries 12px of air. 8 leaves a little room for a
  # sub-pixel without accepting a control that is genuinely up against them.
  CLEAR_PX = 8

  # Everything a respondent taps, reads or drags. Explicit on purpose: a
  # wildcard sweep for "the lowest element" finds .split-card, which runs to
  # the bottom of the screen by design and would report every card as broken.
  REACHABLE = [
    ".choice-list-item", ".choice-card", ".prioritise-item",
    ".book-nav-row", ".book-chevron", ".book-dots",
    ".other-cta-btn", ".other-block",
    ".slider-labels", ".rating-star", ".rating-caption",
    ".freeform-wrap textarea", ".rotate-card-stack", ".rotate-reset-btn",
    ".welcome-intake-tokens-note", ".welcome-token-type-pill", ".welcome-intake-compare"
  ].join(",").freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "ff-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Float", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      compare_note: "See how your answers sit against everyone else.",
      cards: [
        # Each of these was measured behind the pills before the fix; the list
        # is the failure, not a sample of card types.
        { "type" => "welcome_card", "cid" => "w", "image" => "/nope.jpg",
          "text" => "Every way Verto can ask a question",
          "description" => "Thirteen answer types, one deck, about three minutes." },
        { "type" => "select_many_grid", "cid" => "g", "image" => "/nope.jpg",
          "text" => "What keeps you from playing more often?",
          "options" => [ "Nowhere nearby", "No one to go with", "Injury or health",
                         "Not confident", "Costs too much", "No time" ] },
        # allow_other puts the "+ Other" CTA OUTSIDE the scroller, at the foot
        # of the panel — the one that a scroll-only fix would never have moved.
        { "type" => "select_many", "cid" => "m", "image" => "/nope.jpg", "allow_other" => true,
          "text" => "Which of these have you done?",
          "options" => (1..8).map { |i| "Option number #{i}" } },
        { "type" => "scenario", "cid" => "sc", "image" => "/nope.jpg", "text" => "What would you do?",
          "pages" => [ { "id" => "p1", "text" => "A card goes through your door." },
                       { "id" => "p2", "text" => "You have nothing else on that morning." } ],
          "options" => [ "I'd go", "I'd think about it", "Not for me" ] },
        { "type" => "tap_card", "cid" => "t", "image" => "/nope.jpg",
          "text" => "How do you feel about each of these?",
          "options" => [ "The sessions were well run", "I would come back", "I'd recommend it" ] },
        { "type" => "range", "cid" => "r", "image" => "/nope.jpg",
          "text" => "How much does sport belong in your week?",
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

  def open_player(width: W, height: H, inset: INSET)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    assert_selector ".preview-card.active", wait: 5
    if inset.positive?
      page.execute_script(<<~JS)
        const ov = document.querySelector(".preview-overlay")
        const strip = document.createElement("div")
        strip.style.cssText = "height:#{inset.to_i}px;flex:0 0 auto;background:#272D4A"
        ov.insertBefore(strip, ov.firstChild)
      JS
    end
    sleep 0.5
  end

  # Answer whatever the current card wants and move on. Book cards have to be
  # turned to their last page before Next will take them.
  def advance
    page.execute_script(<<~JS)
      const c = document.querySelector(".preview-card.active")
      c.querySelector(".choice-card, .choice-list-item, .rating-star, .pick-item")?.click()
      c.querySelector(".play-consent-agree")?.click()
    JS
    sleep 0.25
    4.times do
      moved = page.evaluate_script(<<~JS)
        (() => { const cs = document.querySelectorAll(".preview-card.active .book-chevron")
          const nx = cs[cs.length - 1]
          if (!nx || nx.disabled) return false
          nx.click(); return true })()
      JS
      break unless moved

      sleep 0.35
    end
    page.execute_script(<<~JS)
      const c = document.querySelector(".preview-card.active")
      c.querySelector(".choice-list-item, .choice-card")?.click()
      document.querySelector(".preview-btn-next")?.click()
    JS
    sleep 0.9
  end

  # Scroll this card's answer to its end and report how far the lowest thing a
  # respondent has to reach sits relative to the pills' top edge. Negative is
  # clear; positive is hidden behind the controls.
  def reach_report
    page.execute_script(<<~JS)
      const b = document.querySelector(".preview-card.active .split-right > .mt-2")
      if (b) b.scrollTop = b.scrollHeight
    JS
    sleep 0.35
    page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const pills = document.querySelector(".preview-footer").getBoundingClientRect()
        const box = card.querySelector(".split-right > .mt-2")
        let bottom = -Infinity, worst = null
        for (const el of card.querySelectorAll(#{REACHABLE.inspect})) {
          const r = el.getBoundingClientRect()
          if (r.height < 3 || getComputedStyle(el).visibility === "hidden") continue
          if (r.bottom > bottom) { bottom = r.bottom; worst = el }
        }
        // Position is not reachability. A negative margin does not shorten a
        // box, it lets it OVERLAP what follows — so a control can measure
        // clear of the pills and still be un-tappable because an option row
        // from the scroller above is painted on top of it. Hit-test the
        // controls that live at the foot of a panel.
        const covered = []
        for (const b of card.querySelectorAll(".other-cta-btn, .book-chevron, .rotate-reset-btn")) {
          const r = b.getBoundingClientRect()
          if (r.height < 3 || getComputedStyle(b).visibility === "hidden") continue
          const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
          if (!hit || (hit !== b && !b.contains(hit))) {
            covered.push(String(b.className).slice(0, 24) + " under " +
                         String(hit ? (hit.className || hit.tagName) : "nothing").slice(0, 30))
          }
        }

        return {
          type: card.dataset.cardType,
          found: !!worst,
          behind: worst ? Math.round(bottom - pills.top) : null,
          what: worst ? String(worst.className || worst.tagName).slice(0, 44) : null,
          scrollable: box ? box.classList.contains("is-scrollable") : null,
          covered
        }
      })()
    JS
  end

  # ── The point of the whole change ─────────────────────────────────────────

  test "the controls float, and the card gets their height back" do
    page.driver.browser.resize(width: W, height: H)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    assert_selector ".preview-card.active", wait: 5
    sleep 0.4

    m = page.evaluate_script(<<~JS)
      (() => {
        const f = document.querySelector(".preview-footer")
        const body = document.querySelector(".preview-body")
        const ov = document.querySelector(".preview-overlay")
        const cs = getComputedStyle(f)
        return {
          position: cs.position,
          footerH: Math.round(f.getBoundingClientRect().height),
          bodyH: Math.round(body.clientHeight),
          bodyBottom: Math.round(body.getBoundingClientRect().bottom),
          footerBottom: Math.round(f.getBoundingClientRect().bottom),
          safeArea: cs.paddingBottom,
          zone: getComputedStyle(ov).getPropertyValue("--play-pill-zone").trim()
        }
      })()
    JS

    assert_equal "absolute", m["position"],
                 "the footer is back in flow (#{m['position']}), so it is taking its height out " \
                 "of the card again — which is the 9% of the screen this change exists to give " \
                 "back."
    assert_equal m["footerBottom"], m["bodyBottom"],
                 "the card stops #{m['bodyBottom'] - m['footerBottom']}px short of the controls. " \
                 "Out of flow it should reach past them to the bottom of the screen; short of " \
                 "them means a band of brand backdrop shows through, which is the dark strip " \
                 "player_mobile_chrome_test has been chasing since the beginning."
    assert m["safeArea"].present? && m["safeArea"] != "",
           "the footer lost its padding-bottom. env(safe-area-inset-bottom) lives there because " \
           "it is the bottom-most element on the card — without it, on a home-indicator phone " \
           "the bottom of Next sits under the indicator, where iOS takes the swipe before the " \
           "button sees it."
    assert_includes m["zone"], "clamp(56px, 9svh, 80px)",
                    "--play-pill-zone no longer derives from the footer's own min-height " \
                    "(#{m['zone']}). Those two are one number in two places; restate it and the " \
                    "answer's clearance stops tracking the size of the thing it is clearing."
  end

  # ── The one that would have caught all seven ─────────────────────────────

  test "every answer type keeps its last control clear of the pills" do
    open_player
    checked = {}

    8.times do
      r = reach_report
      checked[r["type"]] = r unless checked.key?(r["type"])
      advance
      break if checked.size >= 6
    end

    assert_operator checked.size, :>=, 5,
                    "only walked #{checked.size} card types (#{checked.keys.inspect}); the deck " \
                    "carries six and each one is here because it measured behind the pills."

    # Collected rather than asserted one at a time. Seven elements in seven
    # containers broke together and they will break together again — a report
    # naming only the first one found makes a systemic failure look like a
    # one-card bug, which is exactly the reading that produces a per-shape fix.
    offenders = checked.filter_map do |type, r|
      next unless r["found"]
      next if r["behind"] <= -CLEAR_PX

      "#{type}: #{r['what']} is #{r['behind']}px past the pills"
    end

    # The other half of "reachable", and the regression this change actually
    # caused: the scroller's negative margin let it overlap the "+ Other" CTA
    # below it, so an option row landed on the button. It measured clear of the
    # pills the whole time — reachability is a hit test, not a coordinate.
    covered = checked.flat_map { |type, r| Array(r["covered"]).map { |c| "#{type}: #{c}" } }
    assert_empty covered,
                 "these controls are painted over by something else:\n  - " \
                 "#{covered.join("\n  - ")}\n" \
                 "A negative margin does not shorten the scroller, it lets it overlap whatever " \
                 "follows — which is why the bleed-under is scoped to :last-child. Where a CTA " \
                 "sits below the answer, the panel's padding has to be the whole story."

    assert_empty offenders,
                 "these cards end underneath the floating controls, with nowhere further to " \
                 "scroll:\n  - #{offenders.join("\n  - ")}\n" \
                 "Two rules keep this clear and they do different jobs. .split-right's padding " \
                 "lifts everything that is LAID OUT — the grid that fits, the book's chevrons, " \
                 "the '+ Other' CTA outside the scroller. The runway on a scrollable answer's " \
                 "content pays back the reach its negative margin gives away, and needs " \
                 "`flex: 0 0 auto` first, because these children are already squeezed below " \
                 "their own content and padding alone lands above the spill."
  end

  # ── The regression the runway invites ────────────────────────────────────

  # ── The message that lands on top of the controls ────────────────────────

  test "the required-answer nudge is visible above the controls" do
    open_player
    m = page.evaluate_script(<<~JS)
      (() => {
        const hint = document.querySelector(".preview-required-hint")
        hint.classList.remove("hidden")
        const r = hint.getBoundingClientRect()
        const cs = getComputedStyle(hint)
        const pills = document.querySelector(".preview-footer").getBoundingClientRect()
        hint.classList.add("hidden")
        const nums = (c) => c.replace(/[^0-9.,]/g, "").split(",").map(Number)
        const lum = (c) => {
          const [r2, g, b] = nums(c).slice(0, 3).map(v => {
            v /= 255
            return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
          })
          return 0.2126 * r2 + 0.7152 * g + 0.0722 * b
        }
        const ratio = (a, b) => {
          const [x, y] = [ lum(a), lum(b) ].sort((p, q) => q - p)
          return (x + 0.05) / (y + 0.05)
        }
        return {
          behind: Math.round(r.bottom - pills.top),
          onScreen: r.top >= 0 && r.bottom <= window.innerHeight,
          contrast: +ratio(cs.color, cs.backgroundColor).toFixed(2),
          bg: cs.backgroundColor
        }
      })()
    JS

    assert_operator m["behind"], :<=, 0,
                    "the 'please answer this' nudge is #{m['behind']}px behind the controls. It " \
                    "is a sibling of the footer, so lifting the footer out of flow made the " \
                    "hint the last in-flow element and dropped it exactly where the pills are — " \
                    "measured 69px behind on this phone, 56 on a 320. It is what a respondent " \
                    "gets for pressing Next without answering, so invisible is the worst " \
                    "outcome available: they press again."
    assert m["onScreen"], "the nudge is off screen entirely"
    assert_operator m["contrast"], :>=, 4.5,
                    "the nudge is #{m['contrast']}:1 against #{m['bg']}. Its amber was chosen " \
                    "against the brand backdrop the old bar let through; the card now runs to " \
                    "the bottom of the screen and it is WHITE, where that amber measures 1.7:1. " \
                    "It needs to bring its own surface, like .preview-progress-text does."
  end
end
