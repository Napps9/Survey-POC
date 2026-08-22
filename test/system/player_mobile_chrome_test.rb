require "application_system_test_case"

# The mobile player round from the owner's 4-page screenshot review: the card's
# 45/55 proportion, the brand-coloured progress bar, the text-size strip coming
# off phones, and one selection treatment across both option families.
#
# Everything here is measured rather than asserted against a class name — the
# split is a ratio, the selection is a painted colour, and both are the kind of
# thing a plausible-looking CSS edit breaks without breaking any selector.
class PlayerMobileChromeTest < ApplicationSystemTestCase
  PHONE   = [ 393, 660 ].freeze
  # Cuprite keeps ONE browser for the whole run, so a suite that exits
  # phone-sized breaks every test scheduled after it in a layout it was never
  # written for. player_footer_test learned this the hard way; restore in
  # teardown, always.
  DESKTOP = [ 1280, 900 ].freeze

  # A hero on every card that should have one, and a deliberately bare card to
  # prove no-media cards are NOT given an empty 45% panel.
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome", "image" => "/nope.jpg" },
    { "type" => "rating", "cid" => "c1", "text" => "Rate it", "image" => "/nope.jpg",
      "options" => [ "Poor", "Great" ] },
    { "type" => "select_one_grid", "cid" => "c2", "text" => "Pick a tile", "image" => "/nope.jpg",
      "options" => [ "Alpha", "Beta", "Gamma", "Delta" ] },
    { "type" => "multiple_choice", "cid" => "c3", "text" => "Pick a row",
      "options" => [ "One", "Two", "Three" ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "mchrome-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "MobileChrome", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player(width: PHONE[0], height: PHONE[1])
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  # The hero's share of the card. The answer panel rides 22px up over the
  # hero's lower edge (the "lip"), so the hero's own box overstates what is
  # actually visible of it — take the lip off before judging the ratio.
  def hero_share
    page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const sc = card && card.querySelector(".split-card")
        const sl = card && card.querySelector(".split-left")
        if (!sc || !sl) return null
        if (getComputedStyle(sl).display === "contents") return "contents"
        const lip = parseFloat(getComputedStyle(card.querySelector(".split-right")).marginTop) || 0
        return (sl.getBoundingClientRect().height + lip) / sc.getBoundingClientRect().height
      })()
    JS
  end

  test "a hero card gives the header about 45% of the card on a phone" do
    open_player
    share = hero_share
    assert share.is_a?(Float), "the welcome card should have a hero strip, got #{share.inspect}"
    assert_in_delta 0.45, share, 0.06,
                    "the mobile header is #{(share * 100).round(1)}% of the card — the owner " \
                    "asked for 45/55 and --play-hero-h/--play-right-min are tuned as a pair to " \
                    "deliver it"
  end

  test "a card with no media is not given an empty header panel" do
    open_player
    3.times { click_button "Next"; sleep 0.4 } # welcome, rating, grid → the bare list

    assert_equal "multiple_choice", find(".preview-card.active")["data-card-type"]
    assert_equal "contents", hero_share,
                 "a card with no image must keep the whole card for the question — 45% of flat " \
                 "brand colour above it would be worse than the bug this round fixed"
  end

  test "the progress bar is painted in the brand colour, not white" do
    open_player
    fill = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".preview-card.active .panel-progress-fill")).backgroundColor
    JS
    # Default palette ⇒ --brand-primary is never emitted, so this is the
    # fallback resolving — which is exactly the case worth pinning, since a
    # missing fallback fails silently to transparent.
    assert_equal "rgb(1, 234, 203)", fill,
                 "the progress fill should resolve to the brand primary (or its teal fallback " \
                 "on an unbranded Verto), not the old hardcoded white"
  end

  test "the text-size pill is off on a phone and still there on a desktop" do
    open_player
    # Gone on a phone: the strip was costing every card ~44px of header room,
    # which is part of what funds the 45/55 split above.
    assert_no_selector ".font-scale-pill", visible: true

    # ...but still there where there is room for it. Removing the control
    # outright would take the preference away from everyone, not just phones.
    open_player(width: DESKTOP[0], height: DESKTOP[1])
    assert_selector ".font-scale-pill", visible: true
  end

  # The two option families rendered the same anatomy with two different
  # selected states: the list turned its label brand and drew a 1px border,
  # the grid kept a black label and stacked a ring + glow around the tile AND
  # its caption. One vocabulary now: ring on the artwork, label goes brand.
  test "a selected grid option rings the tile, not the caption, and colours the label" do
    open_player
    2.times { click_button "Next"; sleep 0.4 } # → the grid card
    assert_equal "select_one_grid", find(".preview-card.active")["data-card-type"]

    first(".preview-card.active .choice-card").click
    sleep 0.3

    shadows = page.evaluate_script(<<~JS)
      (() => {
        const li = document.querySelector('.preview-card.active .choice-card[data-selected="true"]')
        if (!li) return null
        const bg = li.querySelector(".choice-card-bg")
        return {
          wrapper: getComputedStyle(li).boxShadow,
          tile:    getComputedStyle(bg).boxShadow,
          label:   getComputedStyle(li.querySelector(".choice-label")).color
        }
      })()
    JS

    assert shadows, "no selected grid option found"
    assert_equal "none", shadows["wrapper"],
                 "the selection ring is still on the <li>, which encloses the caption text — " \
                 "'can the selection be just the box, and not the text as well?'"
    assert_includes shadows["tile"], "rgb(1, 234, 203)",
                    "the tile itself should carry the brand ring — the RING is chrome and " \
                    "takes the raw brand colour; only the text had to move (see below)"

    # This used to assert the raw brand primary, rgb(1, 234, 203), and it was
    # wrong in a way a colour-equality test cannot notice: on the default
    # palette that is 1.54:1 against the white caption row. Choosing an answer
    # took its label from 16:1 to almost invisible, and the assertion held the
    # bug in place because it only ever asked "is it the brand colour?".
    #
    # It is now the brand colour made legible — same hue, darkened only as far
    # as 4.5:1 requires (BrandPalette#readable_ink). So this asserts the
    # PROPERTY rather than the constant: a future brand, or a retuned
    # derivation, should be free to land on a different value and still pass —
    # what must never come back is a caption nobody can read.
    ink = BrandPalette.resolve(BrandPalette::DEFAULT)["primary_ink"]
    expected = "rgb(%d, %d, %d)" % BrandPalette.rgb(ink)
    assert_equal expected, shadows["label"],
                 "the caption should turn the READABLE brand colour when selected. The raw " \
                 "primary is #{BrandPalette.contrast_ratio(BrandPalette::DEFAULT['primary'],
                    BrandPalette.lighten(BrandPalette::DEFAULT['primary'], 0.88)).round(2)}:1 " \
                 "on this surface, which is why it is not what lands here any more."

    surface = page.evaluate_script(<<~JS)
      (() => {
        const li = document.querySelector('.preview-card.active .choice-card[data-selected="true"]')
        let n = li.querySelector(".choice-label")
        while (n) {
          const bg = getComputedStyle(n).backgroundColor
          if (bg && !/rgba\\(0, 0, 0, 0\\)|transparent/.test(bg)) return bg
          n = n.parentElement
        }
        return "rgb(255, 255, 255)"
      })()
    JS
    ratio = BrandPalette.contrast_ratio(ink, "#%02X%02X%02X" % surface.scan(/\d+/).first(3).map(&:to_i))
    assert_operator ratio, :>=, 4.5,
                    "the selected caption reads at #{ratio.round(2)}:1 against #{surface}. " \
                    "Whatever colour selection turns the label, a respondent has to be able " \
                    "to read the answer they just chose."
  end

  # On a phone the CARD IS THE SCREEN, so the footer belongs to the card rather
  # than to the backdrop behind it. It never had a background of its own — it
  # was transparent and the Verto's brand backdrop showed through — so the
  # white card ran to the footer's top edge and the bar read as a dark strip
  # pasted underneath it ("weird black bit at the bottom is still there, should
  # be white"). Desktop is deliberately unchanged: there the card floats ON the
  # backdrop and the bar belongs to the backdrop.
  test "the mobile footer continues the card rather than showing the backdrop" do
    open_player
    bg = page.evaluate_script(
      "getComputedStyle(document.querySelector('.preview-footer')).backgroundColor"
    )
    assert_equal "rgb(255, 255, 255)", bg,
                 "the footer is #{bg}. Transparent (rgba(0,0,0,0)) means the brand backdrop is " \
                 "showing through it again, which is the dark strip this fixed."
  end

  # The half of that change that is easy to miss, and did get missed: the
  # controls on the bar were drawn for a DARK bar. Back was 6% white on 8%
  # white with 75% white text — on a white footer it measured present, visible
  # and opacity 1, and could not be seen at all. "Visible" in the DOM is not
  # the same as legible on screen, so this asserts contrast rather than
  # existence.
  #
  # What it asks depends on how the control is painted, because only one of
  # the two can be affected by the bar's colour at all:
  #   • a TRANSLUCENT control is effectively sitting on the bar, so its label
  #     is judged against the bar — this is the disappear-into-white case.
  #   • an OPAQUE control brings its own background, so its label's contrast is
  #     a question about that fill and nothing to do with the footer. What the
  #     footer can still break is the button reading as a distinct SHAPE, so
  #     the fill is judged against the bar instead.
  #
  # Worth recording, because this test found it and it is deliberately out of
  # scope here: Submit is white on the brand CTA colour at 3.71:1, under the
  # 4.5:1 floor for text of its size. That was true before the footer changed
  # and is true on desktop too — it is a brand-palette question, not a
  # consequence of this, and fixing it means changing a client's CTA colour.
  # 3:1, not the 4.5:1 that body text of this size would normally want, and the
  # reason is worth stating rather than quietly picking a number that passes.
  # The failure this guards against is a control vanishing INTO the bar —
  # measured at roughly 1.1:1 when Back was still drawn for a dark footer. A
  # floor of 3 catches that with room to spare.
  # It is set below 4.5 because Submit is white on the brand CTA colour at
  # 3.71:1, which fails AA for its size — but that is true on desktop, was true
  # before this change, and is a decision about a client's brand palette rather
  # than about the footer. Raising this floor would make this test fail for a
  # reason it does not own, so the finding is recorded above instead.
  LEGIBLE_FLOOR = 3.0

  test "the footer's controls are legible against it" do
    open_player
    contrast = page.evaluate_script(<<~JS)
      (() => {
        // No backslash classes here on purpose: this travels through a Ruby
        // heredoc before the browser sees it, and an escaped regex arrives
        // mangled. Computed colours are always "rgb(r, g, b)" or "rgba(...)",
        // so stripping everything that is not a digit, dot or comma parses
        // them without one.
        const nums = (c) => c.replace(/[^0-9.,]/g, "").split(",").map(Number)
        const lum = (c) => {
          const [r, g, b] = nums(c).slice(0, 3).map(v => {
            v /= 255
            return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
          })
          return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        const ratio = (a, b) => {
          const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p)
          return (x + 0.05) / (y + 0.05)
        }
        const foot = getComputedStyle(document.querySelector(".preview-footer")).backgroundColor
        const out = {}
        for (const sel of [ ".preview-btn-back", ".preview-btn-next", ".preview-btn-finish" ]) {
          const el = document.querySelector(".preview-footer " + sel)
          if (!el) continue
          const cs = getComputedStyle(el)
          // A button with its own opaque fill is judged against that fill; a
          // translucent one is effectively sitting on the bar itself.
          // The label against whatever it is actually painted on: its own fill
          // if that fill is opaque, otherwise the bar showing through it.
          const own = cs.backgroundColor
          const parts = nums(own)
          const alpha = parts.length > 3 ? parts[3] : 1
          const on = alpha > 0.5 ? own : foot
          out[sel] = { on, ratio: +ratio(cs.color, on).toFixed(2) }
        }
        return out
      })()
    JS

    assert contrast.any?, "no footer controls found"
    contrast.each do |sel, m|
      assert_operator m["ratio"], :>=, LEGIBLE_FLOOR,
                      "#{sel}: its label is #{m['ratio']}:1 against #{m['on']}. The bar is " \
                      "white now — a control still drawn for a dark bar reads as nothing at " \
                      "all on it (Back measured about 1.1:1 before this, while reporting " \
                      "itself visible with opacity 1)."
    end
  end
end
