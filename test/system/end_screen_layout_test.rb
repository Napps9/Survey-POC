require "application_system_test_case"

# The end screen is drawn in three places — the player, the editor's in-feed
# replica, and the Preview overlay — and they share `.preview-thankyou-card`.
# For one day there was a two-column desktop split on that shared class, given
# only to the player, so the other two had their children auto-placed across
# columns nobody chose. The split is gone; the card is one wide column
# everywhere.
#
# What is worth holding now is not "does it use a grid" but the property the
# split was reaching for and kept breaking: THE EDITOR'S CARD AND THE PLAYER'S
# ARE THE SAME CARD. If they ever compute a different width at the same
# viewport, the editor has stopped showing the creator what a respondent will
# meet — which is the complaint that started all of this.
class EndScreenLayoutTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "open_ended", "cid" => "c1", "text" => "Anything else?" }
  ].freeze

  def setup
    super
    @org = Organisation.create!(name: "Endscreen Co", slug: "endsc-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "End screen", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      thankyou_title: "Thanks for taking part!",
      thankyou_body: "There's plenty more to explore.",
      # Every optional block on, so the actions column is as full as it gets and
      # the editor renders both gate cards.
      forward_url: "https://example.org", forward_label: "Visit our site",
      share_title: "A headline", share_description: "A story.",
      join_prompt_enabled: true, show_results_comparison: true
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    @user = User.create!(name: "U", email_address: "endsc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
  end

  # A live Verto opens the editor behind a "questions are locked" overlay,
  # which sits over the feed and swallows clicks meant for the cards.
  def dismiss_live_warning
    click_button "Got it" if has_button?("Got it", wait: 3)
    assert_no_selector ".live-warning-overlay", wait: 3
  end

  def play_to_the_end
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active .freeform-wrap", wait: 5
    find("[data-player-target='finishBtn']").click
    assert_selector ".preview-thankyou.active", wait: 8
  end

  # The invariant. Every `.preview-thankyou-card` on the page that is actually
  # laying out as a grid must have only `.thankyou-col`s and the `.play-powered`
  # wordmark as children — those are the three things the grid places. Anything
  # else is a child being auto-placed into a column nobody chose for it.
  def assert_no_scrambled_cards(where)
    scrambled = page.evaluate_script(<<~JS)
      [...document.querySelectorAll('.preview-thankyou-card')]
        .filter(card => getComputedStyle(card).display === 'grid')
        .filter(card => [...card.children].some(child =>
          !child.classList.contains('thankyou-col') &&
          !child.classList.contains('play-powered')))
        .map(card => card.className + ' :: ' + [...card.children]
          .map(c => c.className || c.tagName).join(' | '))
    JS
    assert_empty scrambled,
                 "#{where}: a .preview-thankyou-card is laying out as a grid but has children " \
                 "that are neither .thankyou-col nor .play-powered, so grid auto-placement is " \
                 "scattering them across the columns:\n  #{scrambled.join("\n  ")}"
  end

  # gate-cards debounces its POST by 900ms, so a freshly typed value is not on
  # the row the instant the keystroke lands. Poll rather than sleep a fixed
  # amount: a fixed sleep is either flaky or slow, and usually both.
  def eventually(timeout: 6)
    deadline = Time.now + timeout
    loop do
      return true if yield
      break if Time.now > deadline

      sleep 0.15
    end
    false
  end

  def card_metrics
    page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector('.preview-thankyou-card')
        if (!card) return null
        const cs = getComputedStyle(card)
        const msg = card.querySelector('.thankyou-col-message')
        const col = card.querySelector('.thankyou-col')
        return {
          display: cs.display,
          tracks: cs.gridTemplateColumns === 'none'
            ? 0 : cs.gridTemplateColumns.trim().split(/\\s+/).length,
          colDisplay: col ? getComputedStyle(col).display : null,
          messageWidth: msg ? Math.round(msg.getBoundingClientRect().width) : null,
          cardWidth: Math.round(card.getBoundingClientRect().width)
        }
      })()
    JS
  end

  # ── One column, at the deck's width ──────────────────────────────────────

  test "the player's end screen is one wide column on a desktop" do
    with_viewport(1440, 900, mobile: false) do
      play_to_the_end
      m = card_metrics

      refute_equal "grid", m["display"],
                   "the end screen is one column — a split here is the layout that kept " \
                   "scrambling the editor's copy of this card"
      assert_operator m["cardWidth"], :>=, 800,
                      "the card should take the deck's width (850) rather than sitting as a " \
                      "520px strip on a 1440px screen — that was the original complaint"
      assert_operator m["messageWidth"], :<=, 620,
                      "the card is wide but a #{m['messageWidth']}px line of prose is not " \
                      "readable; the message stays capped inside it"
    end
  end

  test "on a phone the wrappers are not layout at all" do
    with_viewport(390, 844) do
      play_to_the_end
      m = card_metrics
      refute_equal "grid", m["display"]
      # Without this the wrappers are real boxes shrink-to-fitting inside a
      # centred flex column, and every percentage width in the card
      # (.play-end-actions, .leaderboard-card, .join-card) resolves against the
      # wrapper instead of the card. It resized the phone player for a day.
      assert_equal "contents", m["colDisplay"],
                   ".thankyou-col must be display:contents, or the card is no longer the flex " \
                   "column its children are sized against"
      assert_operator m["cardWidth"], :<=, 390
    end
  end

  # ── The editor, which is where this broke ─────────────────────────────────

  test "the editor's end-of-Verto cards are not scrambled at any editor width" do
    sign_in_as @user

    # The editor is the case a viewport media query gets wrong: the right panel
    # takes 444px of the window, so the card's container is far narrower than
    # the viewport suggests. All three widths are ordinary laptops.
    [ 1440, 1280, 1152 ].each do |width|
      with_viewport(width, 950, mobile: false) do
        visit survey_path(@survey)
        assert_selector ".gate-ty-card", wait: 8
        assert_no_scrambled_cards "editor at #{width}px"

        # The share card is an unfurl preview, not an end screen. It no longer
        # borrows .preview-thankyou-card at all, which is the durable fix —
        # assert both halves: it exists, and it is not a grid.
        assert_selector ".unfurl-mock", wait: 5
        # (must not borrow the player's card class again — that is what scrambled it)
        assert_no_selector ".unfurl-mock.preview-thankyou-card"
        share_display = page.evaluate_script(
          "getComputedStyle(document.querySelector('.unfurl-mock')).display"
        )
        refute_equal "grid", share_display,
                     "the share card is a preview of a link, not an end screen — never the split"
      end
    end
  end

  # THE invariant. The editor's card and the player's card are the same card,
  # so at the same viewport they must come out the same width. Every version of
  # this bug — the scrambled columns, the 520px strip beside an 850px deck —
  # was this property quietly failing, and it is checkable without knowing what
  # either is supposed to look like.
  test "the editor's card and the player's card are the same card" do
    [ 1440, 1152 ].each do |width|
      player_width = nil
      with_viewport(width, 950, mobile: false) do
        play_to_the_end
        player_width = card_metrics["cardWidth"]
      end

      sign_in_as @user
      editor_width = nil
      with_viewport(width, 950, mobile: false) do
        visit survey_path(@survey)
        assert_selector ".gate-ty-card", wait: 8
        editor_width = page.evaluate_script(
          "Math.round(document.querySelector('.gate-ty-card').getBoundingClientRect().width)"
        )
      end

      assert_in_delta player_width, editor_width, 2,
                      "at #{width}px the player's end screen is #{player_width}px and the " \
                      "editor's replica is #{editor_width}px — the editor has stopped showing " \
                      "the creator the thing a respondent will meet"
    end
  end

  test "the editor's thank-you card puts what you edit above what they also see" do
    sign_in_as @user
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-ty-card", wait: 8

      m = page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector('.gate-ty-card')
          const r = s => { const el = card.querySelector(s); return el ? el.getBoundingClientRect() : null }
          const url = r('#ty-forward-url'), ghosts = r('.gate-ty-ghosts')
          return {
            urlBottom: url && Math.round(url.bottom),
            ghostsTop: ghosts && Math.round(ghosts.top),
            emoji: !!card.querySelector('.preview-thankyou-emoji'),
            joinGhost: !!card.querySelector('.gate-ty-ghost-card')
          }
        })()
      JS

      # The label used to sit ABOVE the Link button inputs, captioning the one
      # editable thing in the column as though it were a preview.
      assert_operator m["ghostsTop"], :>=, m["urlBottom"],
                      "'They'll also see' must sit below the field the creator edits, not above it"
      refute m["emoji"], "the player has no 🎉, so a replica that shows one is not a replica"
      refute m["joinGhost"],
             "the account ask has its own editable card in the feed now — a greyed facsimile of " \
             "it here would be a second, dead copy"
    end
  end

  # Every gate card in the feed is laid over the Verto's BACKGROUND PHOTO, and
  # not every class it borrows from the player is drawn for that. The account
  # ask shipped see-through for a day because `.join-card`'s background is
  # `primary_soft` — rgba(primary, 0.12) for every Verto, a tint that only
  # becomes a card once it composites onto the opaque #1C2034 it sits on in the
  # player. On a photo, 12% of anything composites to nothing.
  #
  # Written as the general rule rather than about that one card: whatever a gate
  # wrapper holds, the creator has to be able to read it.
  test "no gate card in the feed is see-through over the Verto's background" do
    # With the consent gate on as well, all four wrappers are on the page.
    @survey.update_columns(consent_text: "Please agree to take part.")
    sign_in_as @user
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-join-card", wait: 8

      # The rule, stated exactly: a TRANSLUCENT surface — 0 < alpha < 1 — is a
      # fault when nothing opaque stands between it and the photo. Three things
      # this deliberately allows: an element with no surface at all (the
      # thank-you column has none since the outer card went, 2026-09-14 — the
      # player has none either), a tint that sits on an opaque parent (the
      # input rows inside the account card), and THE SCRIM, which is translucent
      # on purpose and is the one translucency that has been measured against
      # the worst photo a Verto can carry rather than assumed (see
      # BrandPalette#readable_surface and EndScreenContrastTest). What it
      # refuses is the fault that happened: a 12% brand tint composited straight
      # onto the background.
      #
      # The scrim is recognised by its VALUE, not by a class, so painting some
      # other translucency and calling it a backdrop still fails here.
      faults = page.evaluate_script(<<~JS)
        (() => {
          const parts = c => { const m = String(c).match(/rgba?\\(([^)]+)\\)/); return m ? m[1].split(',').map(parseFloat) : null }
          const alphaOf = bg => { const p = parts(bg); return !p ? 1 : (p.length > 3 ? p[3] : 1) }
          const same = (a, b) => { const x = parts(a), y = parts(b)
            return !!x && !!y && x.length === y.length && x.every((v, i) => Math.abs(v - y[i]) < 0.001) }
          const out = []
          for (const wrap of document.querySelectorAll('.gate-card-wrap')) {
            if (wrap.hidden || wrap.offsetParent === null) continue
            for (const el of wrap.querySelectorAll('*')) {
              const cs = getComputedStyle(el)
              const a = alphaOf(cs.backgroundColor)
              if (a <= 0 || a >= 1) continue
              // The scrim in force for this element: its own --brand-scrim if
              // the palette reaches here, else the literal the stylesheet falls
              // back to.
              const scrim = cs.getPropertyValue('--brand-scrim').trim() || 'rgba(28, 32, 52, 0.72)'
              if (same(cs.backgroundColor, scrim)) continue
              let opaqueAbove = false
              for (let n = el.parentElement; n && n !== wrap; n = n.parentElement) {
                if (alphaOf(getComputedStyle(n).backgroundColor) >= 1) { opaqueAbove = true; break }
              }
              if (!opaqueAbove) out.push(el.className + ' → ' + cs.backgroundColor)
            }
          }
          return out
        })()
      JS
      assert_empty faults,
                   "a translucent surface reaches the Verto's photo with nothing opaque under it, so the " \
                   "creator sees through it:\n  " + faults.join("\n  ")
    end
  end

  # ...and opaque is not enough on its own: the creator's card must be the SAME
  # colour the respondent sees. Both halves, because painting over the card to
  # stop the photo showing through is the same bug pointing the other way.
  #
  # This used to compare the editor's background-IMAGE against the player's
  # tint, because the card was rgba(primary, 0.12) and the editor reproduced it
  # as a flat gradient over an opaque #1C2034. The card is a solid #272D4A now
  # (Playverto's own surface — it offers a Playverto account, not the Verto),
  # so there is no tint to reproduce and the editor simply inherits. Comparing
  # the computed colours states the property directly, and still fails if
  # either side starts painting its own.
  test "the account-ask card is the same colour as the block it configures" do
    paint = "(() => { const c = getComputedStyle(document.querySelector(arguments[0] || '.join-card')); " \
            "return c.backgroundColor + ' | ' + c.backgroundImage })()"
    player_paint = nil
    with_viewport(1440, 950, mobile: false) do
      play_to_the_end
      player_paint = page.evaluate_script(
        "getComputedStyle(document.querySelector('.join-card')).backgroundColor + ' | ' + " \
        "getComputedStyle(document.querySelector('.join-card')).backgroundImage"
      )
    end

    sign_in_as @user
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-join-card", wait: 8
      editor_paint = page.evaluate_script(
        "getComputedStyle(document.querySelector('.gate-join-card')).backgroundColor + ' | ' + " \
        "getComputedStyle(document.querySelector('.gate-join-card')).backgroundImage"
      )
      assert_equal player_paint, editor_paint,
                   "the editor's account card is painted differently from the block it configures — " \
                   "player #{player_paint.inspect}, editor #{editor_paint.inspect}. They share one rule " \
                   "so that this cannot drift; if it has, something overrode it."
    end
  end

  # Colour was the loud half of "make it a true preview"; arrangement is the
  # quiet half. The card opens COLLAPSED — pitch, button, sign-in line — and
  # the form only appears when the button is tapped (2026-09-14: the full form
  # made the end screen 1127px on an 844px phone). The replica's first paint
  # must be the player's first paint. Compared rather than pinned, so the
  # replica has to follow the block when the block changes.
  test "the account card's first paint is arranged the way the player's is" do
    order = ->(sel) do
      page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector('#{sel}')
          const visible = el => el && el.offsetParent !== null && el.getBoundingClientRect().height > 0
          const top = el => Math.round(el.getBoundingClientRect().top)
          const pick = s => card.querySelector(s)
          const parts = { eyebrow: pick('.join-eyebrow'), title: pick('.join-title'), body: pick('.join-body'),
                          button: pick('.join-row-cta .join-btn'), alt: pick('.join-alt') }
          const seq = Object.entries(parts).filter(([, el]) => visible(el)).sort((a, b) => top(a[1]) - top(b[1])).map(([k]) => k)
          return { seq, formOpen: visible(pick('.join-input')) && !pick('.join-ghosts') }
        })()
      JS
    end

    player = nil
    with_viewport(1440, 950, mobile: false) do
      play_to_the_end
      page.execute_script("document.querySelector('.join-card').classList.remove('hidden')")
      player = order.call(".join-card")
    end

    sign_in_as @user
    editor = nil
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-join-card", wait: 8
      editor = order.call(".gate-join-card")
    end

    assert_equal %w[eyebrow title body button alt], player["seq"],
                 "the player opens on its pitch and one button — if that changed, this test is " \
                 "comparing the editor against the wrong shape"
    refute player["formOpen"], "the form must be behind the button, not open on first paint"
    assert_equal player["seq"], editor["seq"],
                 "the editor's account card is arranged differently from the block it " \
                 "configures (player #{player['seq'].inspect} vs editor #{editor['seq'].inspect})"
    assert_selector ".gate-join-card .join-ghosts .join-input", count: 2,
                    visible: :all
  end

  # And the tap does what the button says: the form appears, the button goes,
  # and focus lands on something the respondent can act on.
  test "tapping the button reveals the form and moves focus into it" do
    with_viewport(390, 844) do
      play_to_the_end
      assert_selector "[data-player-target='joinReveal'] .join-btn", wait: 5
      assert_no_selector ".join-card .join-input" # the form must start hidden

      find("[data-player-target='joinReveal'] .join-btn").click

      assert_selector ".join-card .join-input", count: 2, wait: 5
      # (comment, not an argument — Capybara treats a second positional as an option)
      assert_no_selector "[data-player-target='joinReveal'] .join-btn" # its job done; no second CTA above the first
      focused = page.evaluate_script("document.activeElement && (document.activeElement.className || document.activeElement.tagName)")
      assert_match(/join-google|join-input/, focused.to_s,
                   "focus should land inside the revealed form, not stay on a button that is gone")
    end
  end

  test "the account-ask card is absent when the ask is off" do
    @survey.update_columns(join_prompt_enabled: false)
    sign_in_as @user
    visit survey_path(@survey)
    assert_selector "[data-gate-cards-target='joinCta']:not([hidden])", wait: 8
    assert_selector "[data-gate-cards-target='joinCard'][hidden]", visible: :all
  end

  test "the copy is edited in the feed, not in the publish panel" do
    sign_in_as @user
    visit survey_path(@survey)
    assert_selector ".gate-join-card", wait: 8
    # Two surfaces writing the same columns is how the editor and the player
    # drifted apart before; the panel keeps the switch and nothing else.
    assert_no_selector "input[name='join_title']", visible: :all
    assert_no_selector "textarea[name='join_body']", visible: :all
    assert_no_selector "input[name='join_cta']", visible: :all
  end

  test "editing the heading saves, and removing keeps it for next time" do
    sign_in_as @user
    visit survey_path(@survey)
    assert_selector ".gate-join-card", wait: 8
    dismiss_live_warning

    find("[data-gate-cards-target='joinTitle']").click
    page.send_keys("Keep your results")
    assert eventually { @survey.reload.join_title == "Keep your results" },
           "the heading should autosave; the row still says #{@survey.reload.join_title.inspect}"

    find("[data-action*='gate-cards#removeJoin']").click
    assert_selector "[data-gate-cards-target='joinCta']:not([hidden])", wait: 5
    assert eventually { !@survey.reload.join_prompt_enabled? },
           "removing the card turns the ask off"
    assert_equal "Keep your results", @survey.join_title,
                 "the creator's words are kept — turning the ask back on should not hand them " \
                 "the house copy instead"
  end

  test "the preview overlay's end screen is not scrambled" do
    sign_in_as @user
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-ty-card", wait: 8
      # The overlay's thank-you is server-rendered into the page whether or not
      # it has been opened, so it can be checked without driving the overlay.
      assert_no_scrambled_cards "preview overlay"
    end
  end

  # The overlay's copy was server-rendered once at page load and never
  # refreshed, so a creator who changed the thank-you title and clicked Preview
  # was shown the OLD one — sitting next to question cards that were perfectly
  # up to date, because those have always been re-cloned from the live feed.
  #
  # Deliberately types and previews inside gate-cards' 900ms save debounce:
  # the preview reads the editor's DOM, not the persisted row, so it must be
  # right before the save lands rather than a second afterwards.
  test "the preview overlay shows the copy in the editor, not the copy on the row" do
    sign_in_as @user
    visit survey_path(@survey)
    assert_selector ".gate-ty-card", wait: 8

    dismiss_live_warning
    title = find("[data-gate-cards-target='tyTitle']")
    title.click
    title.send_keys([ :control, "a" ], "Edited but not yet saved")

    # The publish panel holds the Preview button and may be collapsed; the
    # controller action is what is under test, not the panel's disclosure.
    page.execute_script("document.querySelector(\"[data-action*='preview-verto#open']\").click()")

    # Read the node rather than waiting for it to be visible: the overlay opens
    # on the FIRST card and only reveals the thank-you once the reader finishes,
    # while the sync this test is about happens at open. Content, not visibility.
    shown = page.evaluate_script(
      "document.querySelector(\"[data-preview-verto-target='thankyouTitle']\").textContent.trim()"
    )
    assert_equal "Edited but not yet saved", shown,
                 "Preview is showing the copy the page booted with rather than the copy on screen"
  end
  # ── The two ways in, on the card itself ───────────────────────────────────

  # Capybara's Puma runs in this process, so SocialAuth — which reads ENV on
  # every call — sees a change made here. The OmniAuth middleware does not (it
  # is built from ENV at boot), which is fine: what is under test is the card,
  # not the round trip. PlayerGoogleJoinTest drives the three hops.
  def with_google
    ENV["GOOGLE_CLIENT_ID"]     = "test-id"
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"
    yield
  ensure
    ENV.delete("GOOGLE_CLIENT_ID")
    ENV.delete("GOOGLE_CLIENT_SECRET")
  end

  test "the card offers Google above the address rows, and a sign-in door below" do
    with_google do
      with_viewport(390, 844) do
        play_to_the_end
        find("[data-player-target='joinReveal'] .join-btn").click
        assert_selector ".join-card .join-google", wait: 5

        geometry = page.evaluate_script(<<~JS)
          (() => {
            const card = document.querySelector('.join-card')
            const top = s => { const el = card.querySelector(s); return el ? Math.round(el.getBoundingClientRect().top) : null }
            const link = card.querySelector('.join-alt-link')
            return { google: top('.join-google'), email: top('.join-input'),
                     divider: top('.join-divider'), alt: top('.join-alt'),
                     href: link && link.getAttribute('href'),
                     target: link && link.getAttribute('target') }
          })()
        JS

        assert_operator geometry["google"], :<, geometry["divider"]
        assert_operator geometry["divider"], :<, geometry["email"],
                        "Google is the shorter road and goes first; the divider separates the two"
        assert_operator geometry["email"], :<, geometry["alt"],
                        "the sign-in door is the way out for the few, not the path for the many"
        assert_equal new_player_session_path, geometry["href"]
        # A Verto is routinely framed by a third party, where following this in
        # place would replace somebody else's page with a sign-in form.
        assert_equal "_blank", geometry["target"]
      end
    end
  end

  test "without credentials the card keeps the sign-in door and drops the button" do
    with_viewport(390, 844) do
      play_to_the_end
      assert_selector ".join-card", wait: 5
      find("[data-player-target='joinReveal'] .join-btn").click
      assert_selector ".join-card .join-input", wait: 5

      # No message arguments: Capybara's second positional is a selector
      # option, not a failure message, and it raises on an unknown one.
      assert_no_selector ".join-card .join-google" # a button that goes nowhere
      assert_selector ".join-card .join-alt-link"  # does not depend on Google
    end
  end

  # The editor's replica has to follow, or it stops being a preview of what a
  # respondent meets — the property the rest of this file exists to hold.
  test "the editor's account card shows the same two doors the player does" do
    with_google do
      sign_in_as @user
      with_viewport(1440, 950, mobile: false) do
        visit survey_path(@survey)
        assert_selector ".gate-join-card", wait: 8

        assert_selector ".gate-join-card .join-google"
        assert_selector ".gate-join-card .join-alt"
        # Inert: the creator is looking at the respondent's side of the card,
        # and none of it is theirs to press.
        assert_equal "none", page.evaluate_script(
          "getComputedStyle(document.querySelector('.gate-join-card .join-google')).pointerEvents"
        )
        assert_no_selector ".gate-join-card .join-google button"
        assert_no_selector ".gate-join-card .join-alt a"
      end
    end
  end

  # ── The message box, which is the field ────────────────────────────────
  #
  # The end screen's message box starts EMPTY now, behind a placeholder: it
  # used to arrive holding the "from <account>" byline, so a creator who only
  # opened the card had the byline saved as their message. Which made the
  # collapse rule added for the PLAYER — an end screen with no message must not
  # hold a gap open where one would be — a rule that also hid the editor's
  # field. Nowhere to type the message at all, on the one surface whose whole
  # job is typing it. .q-subtitle carries the same guard for the same reason.
  test "the editor's empty message box is still there to be typed into" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    dismiss_live_warning

    box = find("[data-gate-cards-target='tyBody']", visible: :all)
    page.execute_script("arguments[0].textContent = ''; arguments[0].scrollIntoView({ block: 'center' })", box)

    assert_equal "block", page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector("[data-gate-cards-target='tyBody']")).display
    JS

    # And the placeholder is what fills it, rather than a value.
    assert_equal I18n.t("editor.ty_body_placeholder"), page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector("[data-gate-cards-target='tyBody']"), "::before")
        .content.replace(/^"|"$/g, "")
    JS
  end

  # The player still collapses it, which is the half the rule was written for.
  test "a respondent with no message to read gets no gap where one would be" do
    @survey.update!(thankyou_body: "")
    play_to_the_end

    assert_equal "none", page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".preview-thankyou.active .preview-thankyou-sub")).display
    JS
    assert_selector ".preview-thankyou.active .preview-thankyou-from",
                    text: "from Endscreen Co"
  end

  # The Preview overlay reads the editor's boxes rather than the saved deck, and
  # its copy() helper fell back to the box's data-default-text when the creator
  # had written nothing. That attribute is the PLACEHOLDER now, so the fallback
  # put "Add a short message (optional)" on a respondent-facing preview.
  test "the Preview overlay shows no message rather than the editor's placeholder" do
    @survey.update!(thankyou_body: "")
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    dismiss_live_warning

    page.execute_script("document.querySelector(\"[data-action*='preview-verto#open']\").click()")
    assert_selector ".preview-overlay .preview-thankyou", visible: :all, wait: 10

    shown = page.evaluate_script(<<~JS)
      (document.querySelector(".preview-overlay [data-preview-verto-target='thankyouBody']")?.textContent || "").trim()
    JS
    assert_equal "", shown,
                 "the previewed end screen is reading the editor's placeholder as the message"
    assert_equal "Thanks for taking part!", page.evaluate_script(<<~JS)
      (document.querySelector(".preview-overlay [data-preview-verto-target='thankyouTitle']")?.textContent || "").trim()
    JS
  end
end
