require "application_system_test_case"

# The end screen is drawn in three places — the player, the editor's in-feed
# replica, and the Preview overlay — and `.preview-thankyou-card` is shared by
# all three. When the desktop split was added it put `display: grid` on that
# shared class and gave only the PLAYER the two `.thankyou-col` wrappers the
# grid expects. The other two kept flat child lists, so grid auto-placement
# dealt their children across the columns: the editor's thank-you title jumped
# into the right-hand column beside the 🎉, and the share card became a 2x2.
#
# Nothing failed. The whole 440-run system suite stayed green, because every
# assertion about this card was about the player, and the player was the one
# copy that had been updated.
#
# So the assertion this file exists for is structural rather than pictorial:
# a card that is a grid must contain ONLY things the grid was designed to
# place. That is true of all three copies, it is checkable without knowing what
# any of them should look like, and it fails on the next copy somebody adds
# without wrappers.
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

  # ── The player ────────────────────────────────────────────────────────────

  test "the player's end screen splits on a desktop and stacks on a phone" do
    with_viewport(1440, 900, mobile: false) do
      play_to_the_end
      assert_no_scrambled_cards "player at 1440x900"

      m = card_metrics
      assert_equal "grid", m["display"], "the desktop end screen should be the two-column split"
      assert_equal 2, m["tracks"], "expected exactly two grid tracks, got #{m['tracks']}"
      assert_operator m["messageWidth"], :>=, 280,
                      "the message column came out at #{m['messageWidth']}px — 44px display type " \
                      "needs room, and a column this narrow means the split fired somewhere it " \
                      "does not fit"
    end
  end

  test "on a phone the wrappers are not layout at all" do
    with_viewport(390, 844) do
      play_to_the_end
      m = card_metrics
      refute_equal "grid", m["display"], "a phone end screen should be the single flex column"
      # The base rule. Without it the wrappers are real boxes shrink-to-fitting
      # inside a centred flex column, and every percentage width in the card
      # (.play-end-actions, .leaderboard-card, .join-card) resolves against the
      # wrapper instead of the card.
      assert_equal "contents", m["colDisplay"],
                   ".thankyou-col must be display:contents outside the split, or the card is no " \
                   "longer the flex column its children are sized against"
    end
  end

  # A portrait iPad and a landscape phone are the two shapes the player's own
  # mobile boundary calls mobile. The split used to be keyed to a bare
  # `min-width: 768px`, which called both of them desktop and handed 44px type a
  # column barely wider than a word.
  test "the shapes the player already calls mobile do not get the split" do
    [ [ 768, 1024, "portrait tablet" ], [ 844, 390, "landscape phone" ] ].each do |w, h, label|
      with_viewport(w, h) do
        play_to_the_end
        m = card_metrics
        next if m["display"] != "grid"

        assert_operator m["messageWidth"], :>=, 280,
                        "#{label} (#{w}x#{h}): split with a #{m['messageWidth']}px message column"
      end
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

  # The replica is only worth the name if the parts land where the player puts
  # them. Geometry rather than screenshots: the message and the actions are in
  # different columns, and nothing has drifted back into the wrong one.
  test "the editor's thank-you card is laid out like the player's end screen" do
    sign_in_as @user
    with_viewport(1440, 950, mobile: false) do
      visit survey_path(@survey)
      assert_selector ".gate-ty-card", wait: 8

      m = page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector('.gate-ty-card')
          const r = s => { const el = card.querySelector(s); return el ? el.getBoundingClientRect() : null }
          const title = r('.preview-thankyou-title'), body = r('.preview-thankyou-sub')
          const url = r('#ty-forward-url')
          return {
            display: getComputedStyle(card).display,
            tracks: getComputedStyle(card).gridTemplateColumns.trim().split(/\\s+/).length,
            messageWidth: Math.round(r('.thankyou-col-message').width),
            titleLeft: title && Math.round(title.left),
            bodyLeft: body && Math.round(body.left),
            urlLeft: url && Math.round(url.left),
            titleRight: title && Math.round(title.right),
            emoji: !!card.querySelector('.preview-thankyou-emoji')
          }
        })()
      JS

      assert_equal "grid", m["display"], "the replica should use the same split as the player"
      assert_equal 2, m["tracks"]
      assert_operator m["messageWidth"], :>=, 280,
                      "message column is #{m['messageWidth']}px — the editor's card is narrower " \
                      "than the window by the width of the right panel, which is why this is a " \
                      "container query and not a media query"
      assert_in_delta m["titleLeft"], m["bodyLeft"], 1,
                      "title and body should share the message column's left edge"
      assert_operator m["urlLeft"], :>=, m["titleRight"],
                      "the link-button input belongs in the actions column, to the right of the " \
                      "message — if it is not, the wrappers are gone and grid auto-placement is back"
      refute m["emoji"], "the player has no 🎉, so a replica that shows one is not a replica"
    end
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
