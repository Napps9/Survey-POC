require "application_system_test_case"

# The two captions beside a liquid scale's ends, in a browser.
#
#   "We need a short line of text to the left of 0 and to the left of 10. This
#    is so it's clear what the scale is. The text next to 0 could read 'I have
#    no say at all' and the text to the left of 10 could read 'I am a decision
#    maker'. Having these editable per NPS question would be good as the scales
#    relate to the question asked."
#
# Three things can only be checked here. That the captions LINE UP with the two
# end stops — they are a separate column sharing the digits' track, so the
# alignment is a CSS contract rather than markup, and it has to hold at any step
# count. That they survive the editor's DOM round-trip (the deck is rebuilt from
# the rendered card on every autosave, so a field the serialiser cannot read
# back is a field that silently reverts). And that the column, which wraps,
# never pushes the answer panel into a scroll.
class NpsAnchorsTest < ApplicationSystemTestCase
  LOW   = "I have no say at all".freeze
  HIGH  = "I am a decision maker".freeze
  AGREE = [ "Never", "Rarely", "Sometimes", "Often", "Always" ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Unleash Football", slug: "anch-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "A", email_address: "anch-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    # Two Vertos of the same deck, on purpose: a LIVE one for the player, and a
    # draft for the editor. A live Verto's editor is covered by the
    # live-warning overlay, which intercepts every click in the feed.
    @survey = @org.surveys.create!(title: "Say", **deck)
    @live   = @org.surveys.create!(title: "Say live", **deck)
    @live.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def deck
    { theme: "Football", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        # Classic 0-10, no captions yet — the card the request is about.
        { "type" => "nps", "cid" => "n1", "text" => "How much say do you feel like you have in football?" },
        # A five-point scale that already carries captions, on the widest
        # vessel there is (mug) — the tightest the column will ever be.
        { "type" => "nps", "cid" => "n2", "text" => "How often?", "options" => AGREE.dup,
          "nps_shape" => "mug", "nps_low_label" => LOW, "nps_high_label" => HIGH }
      ] }
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How often?"
  end

  def open_player
    visit "/play/#{@live.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
  end

  def anchor(cid, which)
    find("[data-card-cid='#{cid}'] .nps-anchor-#{which}")
  end

  def stored(cid)
    30.times do
      card = @survey.reload.cards.find { |c| c["cid"] == cid }
      return card if yield(card)
      sleep 0.5
    end
    @survey.reload.cards.find { |c| c["cid"] == cid }
  end

  # No click: the caption sits in a zero-height row inside a feed that scrolls
  # when a card is selected, so a click aimed at its centre could land on a
  # neighbour by the time it was delivered. send_keys focuses the node itself
  # and types into it, which is the path under test anyway.
  def type_into(node, text)
    page.execute_script(
      "arguments[0].scrollIntoView({ block: 'center' }); arguments[0].textContent = ''; arguments[0].focus()", node
    )
    press_keys(text)
    # The blur makes the reading unambiguous — an input event is queued on every
    # keystroke and the save is debounced behind it.
    page.execute_script("arguments[0].blur()", node)
  end

  # Do the captions sit on the two end stops, and does the column fit?
  #
  # The centre of a single line of caption against the centre of the digit it
  # names: the row each lives in is zero-height and marks the stop itself, so
  # "level with the stop" is the same statement as "level with the digit".
  def geometry(scope)
    evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector(#{scope.to_json})
        const rows = [...wrap.querySelectorAll(".nps-label-row .slider-label-text")]
        const mid  = (r) => (r.top + r.bottom) / 2
        const lowDigit  = rows[0].getBoundingClientRect()
        const highDigit = rows[rows.length - 1].getBoundingClientRect()
        const lowEl  = wrap.querySelector(".nps-anchor-low")
        const highEl = wrap.querySelector(".nps-anchor-high")
        const low  = lowEl.getBoundingClientRect()
        const high = highEl.getBoundingClientRect()
        // The captions hang toward the middle of the scale, so the line that is
        // level with the stop is the bottom caption's LAST and the top
        // caption's FIRST — not the middle of either box. The 0.6em is the
        // negative margin that puts that line's centre on the stop; read off
        // the element so a font-size change cannot make this lie.
        const lead = (el) => 0.6 * parseFloat(getComputedStyle(el).fontSize)
        const lineH = (el) => parseFloat(getComputedStyle(el).lineHeight)
        const box  = wrap.closest(".split-right")?.querySelector(":scope > .mt-2")
        return {
          lowOff:  Math.round((low.bottom - lead(lowEl)) - mid(lowDigit)) || 0,
          highOff: Math.round((high.top + lead(highEl)) - mid(highDigit)) || 0,
          // How hard the column is wrapping. Level but nine lines deep is what
          // the widest vessels used to produce before they gave up some width.
          lowLines:  Math.round(low.height / lineH(lowEl)) || 0,
          highLines: Math.round(high.height / lineH(highEl)) || 0,
          // The caption reads leading-side of its number, which is the whole
          // point of "to the left of 0" — and proves the column is the first
          // one in the stage rather than appended past the vessel.
          lowBeforeDigit:  low.right  <= lowDigit.left + 1,
          highBeforeDigit: high.right <= highDigit.left + 1,
          // Never past the ends of the scale: a caption that hung below stop 0
          // or above the top stop would be the thing that pushes the panel
          // into a scroll.
          withinLow:  low.bottom <= lowDigit.bottom + 2,
          withinHigh: high.top >= highDigit.top - 2,
          overflowX: box ? Math.round(box.scrollWidth - box.clientWidth) : null,
          overflowY: box ? Math.round(box.scrollHeight - box.clientHeight) : null,
          stops: rows.length
        }
      })()
    JS
  end

  def assert_level(g, where)
    assert_operator g["lowOff"].abs, :<=, 2,
                    "#{where}: the low caption sits #{g['lowOff']}px off its own stop. The " \
                    "captions share the digits' track precisely so this cannot drift."
    assert_operator g["highOff"].abs, :<=, 2,
                    "#{where}: the high caption sits #{g['highOff']}px off its own stop"
    assert g["lowBeforeDigit"], "#{where}: the low caption is not to the left of its number"
    assert g["highBeforeDigit"], "#{where}: the high caption is not to the left of its number"
    assert g["withinLow"], "#{where}: the low caption hangs below the bottom of the scale"
    assert g["withinHigh"], "#{where}: the high caption reaches above the top of the scale"
  end

  # Readability, which is a different question from alignment: the captions are
  # still level with their stops at any wrap depth (the line alignment does not
  # care), but a column squeezed to one word per line is not a caption anyone
  # reads. Asserted where the scale is a realistic one — the digits are
  # non-shrinkable, so a scale carrying unusually long word labels has less
  # width to give and its captions wrap harder by design.
  def assert_readable(g, where)
    [ [ "low", g["lowLines"] ], [ "high", g["highLines"] ] ].each do |side, lines|
      assert_operator lines, :<=, 4,
                      "#{where}: the #{side} caption wrapped to #{lines} lines"
    end
  end

  def assert_no_panel_scroll(g, where)
    assert_equal 0, g["overflowX"], "#{where}: the captions pushed the answer panel sideways"
    assert_equal 0, g["overflowY"], "#{where}: the captions pushed the answer panel into a scroll"
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  # ── The player, which is what a respondent actually meets ──────────────

  test "a respondent sees both captions level with the ends of the scale" do
    open_player
    click_button "Next"          # off the welcome card, onto n1 (no captions)
    assert_selector ".preview-card.active .nps-slider", wait: 5
    assert page.has_no_css?(".preview-card.active .nps-anchors", visible: :all, wait: 2),
           "a card with no captions should draw no column at all"

    click_button "Next"
    assert_selector ".preview-card.active .nps-anchor-low", text: LOW, wait: 5
    settle_box find(".preview-card.active .nps-slider-stage")

    g = geometry(".preview-card.active .nps-slider")
    assert_equal 5, g["stops"]
    assert_level g, "player, five-point scale on a mug"
    assert_readable g, "player, five-point scale on a mug"
    assert_no_panel_scroll g, "player, five-point scale on a mug"
  end

  test "the captions hold their stops on a phone, where the vessel is smaller" do
    with_viewport(390, 700) do
      open_player
      click_button "Next"
      click_button "Next"
      assert_selector ".preview-card.active .nps-anchor-low", text: LOW, wait: 5
      settle_box find(".preview-card.active .nps-slider-stage")

      g = geometry(".preview-card.active .nps-slider")
      assert_level g, "phone player"
      assert_readable g, "phone player"
      assert_no_panel_scroll g, "phone player"
    end
  end

  # The reading a screen reader gets at the two ends. A number on its own says
  # nothing about the scale, which is the whole complaint.
  test "the scale announces what its ends mean, not just their numbers" do
    open_player
    click_button "Next"
    click_button "Next"
    assert_selector ".preview-card.active .nps-anchor-low", wait: 5

    slider = find(".preview-card.active .nps-slider")
    slider.click                                  # answers wherever the click lands
    page.execute_script(<<~JS)
      const s = document.querySelector(".preview-card.active .nps-slider")
      s.focus()
    JS
    12.times { press_keys :down }                 # drive it to the bottom stop

    assert_equal "Never — #{LOW}", slider["aria-valuetext"]
    12.times { press_keys :up }
    assert_equal "Always — #{HIGH}", slider["aria-valuetext"]
  end

  # ── The editor, which is where they are written ────────────────────────

  test "captions typed in the editor survive the autosave round-trip and a reload" do
    open_editor

    type_into anchor("n1", "low"), LOW
    type_into anchor("n1", "high"), HIGH

    card = stored("n1") { |c| c["nps_low_label"] == LOW && c["nps_high_label"] == HIGH }
    assert_equal LOW,  card["nps_low_label"]
    assert_equal HIGH, card["nps_high_label"]

    # The deck is rebuilt from the DOM on every autosave, so the reload is the
    # half that matters: a field the serialiser cannot read back reverts.
    visit survey_path(@survey)
    assert_selector "[data-card-cid='n1'] .nps-anchor-low", text: LOW, wait: 5
    assert_selector "[data-card-cid='n1'] .nps-anchor-high", text: HIGH
  end

  test "clearing one caption leaves the other alone" do
    open_editor

    node = anchor("n2", "low")
    node.click
    page.execute_script("arguments[0].textContent = ''; arguments[0].dispatchEvent(new Event('input', { bubbles: true }))", node)

    card = stored("n2") { |c| !c.key?("nps_low_label") }
    refute card.key?("nps_low_label"), "a caption cleared to nothing should not persist as ''"
    assert_equal HIGH, card["nps_high_label"], "the other end lost its caption too"
  end

  # The captions are copy beside the scale, not part of it: the Classic switch
  # REPLACES the stops (that is what makes an NPS score comparable), and it
  # rebuilds the digit column's markup wholesale to do it. Anything living
  # inside that column would be destroyed — which is why this is a sibling.
  test "captions survive the Classic switch and editing the scale" do
    open_editor
    type_into anchor("n1", "low"), LOW
    stored("n1") { |c| c["nps_low_label"] == LOW }

    find("[data-card-cid='n1'] .split-right").click
    assert_selector "[data-survey-editor-target='npsClassic']:not([hidden])", wait: 5
    find("[data-survey-editor-target='npsClassic'] .card-flag").click   # off the classic
    assert_selector "[data-card-cid='n1'] .nps-scale-add", wait: 5

    assert_equal LOW, anchor("n1", "low").text, "the caption went with the rebuilt column"

    find("[data-card-cid='n1'] .nps-scale-add").click                   # a twelfth... stop
    assert_equal LOW, anchor("n1", "low").text

    card = stored("n1") { |c| c["nps_low_label"] == LOW }
    assert_equal LOW, card["nps_low_label"]
  end

  test "the captions stay level as the scale's step count changes" do
    open_editor
    settle_box find("[data-card-cid='n2'] .nps-slider-stage")
    g = geometry("[data-card-cid='n2'] .nps-slider")
    assert_level g, "editor, five stops"
    assert_readable g, "editor, five stops"
    assert_no_panel_scroll g, "editor, five stops"

    find("[data-card-cid='n2'] .split-right").click
    assert_selector "[data-card-cid='n2'] .nps-scale-add", wait: 5
    find("[data-card-cid='n2'] .nps-scale-add").click
    assert_selector "[data-card-cid='n2'] .nps-label-row", count: 6, wait: 5

    settle_box find("[data-card-cid='n2'] .nps-slider-stage")
    g = geometry("[data-card-cid='n2'] .nps-slider")
    # Alignment only here. Selecting the card opens the right-hand panel, which
    # narrows the feed — and the stop the ＋ just added is labelled with the
    # editor's own placeholder, wider than any of the five words already there.
    # That combination overflows the answer pane by 28px, and measured with the
    # captions and without them it is the same 28px: the digits are what does
    # not fit (they own their width — a squeezed scale paints its labels over
    # its own delete chips), and on the widest vessel it overflowed by more
    # before the captions existed, because the vessel was 248px rather than the
    # 200 an anchored card now draws. So this case is about the captions
    # tracking the stops as the count changes, which is what it asserts.
    assert_level g, "editor, six stops"
  end

  # An empty column is the editor's own state, and the preview overlay clones
  # the editor's DOM — so without this the previewed card would carry a gap the
  # real player does not, and the vessel would sit somewhere else.
  test "the preview overlay drops a column the creator never filled" do
    open_editor
    page.execute_script("document.querySelector(\"[data-action*='preview-verto#open']\").click()")
    assert_selector ".preview-overlay .preview-card", wait: 10

    empty = evaluate_script(<<~JS)
      (() => {
        const cards = [...document.querySelectorAll(".preview-overlay .preview-card")]
        const withSlider = cards.filter((c) => c.querySelector(".nps-slider"))
        return withSlider.map((c) => {
          const col = c.querySelector(".nps-anchors")
          if (!col) return "none"
          return [...col.querySelectorAll(".nps-anchor-text")].some((e) => e.textContent.trim())
            ? "filled" : "empty"
        })
      })()
    JS

    assert_includes empty, "none", "the un-captioned card should carry no column in the preview"
    refute_includes empty, "empty", "an empty column costs a stage gap the player does not pay"
    refute_includes empty.to_s, "contenteditable"
  end
end
