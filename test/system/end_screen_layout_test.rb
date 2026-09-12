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
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
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

      cards = page.evaluate_script(<<~JS)
        [...document.querySelectorAll('.gate-card-wrap')]
          .filter(wrap => !wrap.hidden && wrap.offsetParent !== null)
          .map(wrap => wrap.lastElementChild)
          .filter(Boolean)
          .map(card => {
            const bg = getComputedStyle(card).backgroundColor
            const parts = (bg.match(/rgba?\\(([^)]+)\\)/) || [ , '' ])[1].split(',')
            return { name: card.className, bg: bg,
                     alpha: parts.length > 3 ? parseFloat(parts[3]) : 1 }
          })
      JS

      assert_operator cards.size, :>=, 4,
                      "only #{cards.size} gate cards on the page — this test proves nothing " \
                      "unless the feed is actually rendering them"
      see_through = cards.reject { |c| c["alpha"] == 1.0 }
      assert_empty see_through,
                   "a gate card is drawn on a translucent background, so the Verto's photo " \
                   "shows through it and the creator cannot read their own copy:\n  " +
                   see_through.map { |c| "#{c['name']} → #{c['bg']}" }.join("\n  ")
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
    # Read off the player's own .join-card rather than hard-coded, so the check
    # follows the card wherever its surface goes next.
    player_bg = nil
    with_viewport(1440, 950, mobile: false) do
      play_to_the_end
      player_bg = page.evaluate_script(
        "getComputedStyle(document.querySelector('.join-card')).backgroundColor"
      )
    end

    sign_in_as @user
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-join-card", wait: 8
      editor = page.evaluate_script(<<~JS)
        (() => { const s = getComputedStyle(document.querySelector('.gate-join-card'))
                 return { color: s.backgroundColor, image: s.backgroundImage } })()
      JS

      assert_equal player_bg, editor["color"],
                   "the editor's account card is a different colour from the one the respondent " \
                   "meets (player #{player_bg}, editor #{editor['color']}) — the creator is " \
                   "editing a card nobody sees."
      # A gradient over the top would composite to something else again, which
      # is exactly how the two drifted apart the first time.
      assert_equal "none", editor["image"],
                   "the editor's account card paints over the inherited surface " \
                   "(#{editor['image'].inspect}), so the two can drift again."
    end
  end

  # ── The account ask, which is edited in the feed rather than a side panel ──

  test "the account-ask card appears when the ask is on, and carries the copy" do
    sign_in_as @user
    visit survey_path(@survey)
    assert_selector ".gate-join-card", wait: 8

    assert_selector "[data-gate-cards-target='joinCard']:not([hidden])"
    assert_selector "[data-gate-cards-target='joinCta'][hidden]", visible: :all
    # The three the creator owns are editable...
    %w[joinTitle joinBody joinCtaText].each do |target|
      assert_selector "[data-gate-cards-target='#{target}'][contenteditable='true']"
    end
    # ...and the respondent's own rows are shown but inert, so the shape is
    # honest without pretending the boxes work. Both of them: the password row
    # arrived with the choose-a-password change.
    assert_selector ".gate-join-card .gate-join-ghost", count: 2
  end

  # Colour was the loud half of "make it a true preview"; arrangement is the
  # quiet half. The button used to sit on a row of its own with no length hint
  # above it, so the creator was writing a button in a place no respondent ever
  # meets it. Compares the two rather than pinning either, so the replica has to
  # follow the block when the block changes.
  test "the account card's rows are arranged the way the player's are" do
    rows = ->(sel) do
      page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector('#{sel}')
          const top = el => el ? Math.round(el.getBoundingClientRect().top) : null
          const inputs = [...card.querySelectorAll('.join-input')]
          const btn = card.querySelector('.join-btn')
          return { inputs: inputs.length,
                   sameRowAsPassword: top(inputs[1]) === top(btn),
                   hint: !!card.querySelector('.join-note') }
        })()
      JS
    end

    player = nil
    with_viewport(1440, 950, mobile: false) do
      play_to_the_end
      page.execute_script("document.querySelector('.join-card').classList.remove('hidden')")
      player = rows.call(".join-card")
    end

    sign_in_as @user
    editor = nil
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-join-card", wait: 8
      editor = rows.call(".gate-join-card")
    end

    assert player["sameRowAsPassword"],
           "the player is meant to put the button beside the password — if that changed, this " \
           "test is comparing the editor against the wrong shape"
    assert_equal player, editor,
                 "the editor's account card is arranged differently from the block it " \
                 "configures (player #{player.inspect} vs editor #{editor.inspect})"
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
end
