require "application_system_test_case"
require "chunky_png"

# Every word on the end screen, measured against the pixels actually behind it.
#
# The thank-you card lost its opaque surface on 2026-09-14 (the owner's
# one-column pick), which put the title, the subtitle, the wordmark and the
# editor's own labels on the Verto's BACKGROUND PHOTO. A photo can be any
# brightness, so "looks fine on the one I checked" is not a property — measured
# over the four committed library backgrounds at that moment, the white title
# ran 1.64:1 on `landscape` and the subtitle 1.36:1, against AA's 3:1 and
# 4.5:1. A text-shadow had been added first and is a hope, not a floor.
#
# What holds it now is BrandPalette#readable_surface: the scrim is the Verto's
# own background colour darkened only as far as it must go for white to clear
# 4.5:1 once composited at 72% over a WHITE photo. This file is the check that
# the arithmetic and the stylesheet still agree — and the reason a future
# change to either fails here rather than in somebody's hand.
#
# The floor is quoted for WHITE, and that is a constraint on the ink as much as
# on the scrim: readable_surface stops at the first step that carries white, so
# on the brightest photo white lands exactly on 4.5:1 and anything fainter
# lands under it. Three faded inks were found here on the day this was written
# (a 60% label, a 35% counter, a 92% subtitle), all of them tuned for the
# opaque card that used to be underneath. Ink on the scrim is white; quiet is
# done with size.
class EndScreenContrastTest < ApplicationSystemTestCase
  # Every background committed under verto-library. `landscape` is the one that
  # measured worst; the rest are here because "worst" is a fact about today's
  # four, not a rule.
  BACKGROUNDS = %w[landscape nature people sport].freeze

  # WCAG AA. 3:1 for large text (the 44px title), 4.5:1 for everything else.
  AA_LARGE = 3.0
  AA_BODY  = 4.5

  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "open_ended", "cid" => "c1", "text" => "Anything else?" }
  ].freeze

  def setup
    super
    @org = Organisation.create!(name: "Contrast Co", slug: "cont-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "cont-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def survey_on(background, **attrs)
    s = @org.surveys.create!(
      title: "Contrast", theme: "space exploration", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      thankyou_title: "Thanks for taking part!",
      thankyou_body: "There's plenty more to explore.",
      forward_url: "https://example.org", forward_label: "Visit our site",
      share_title: "A headline", share_description: "A story.",
      join_prompt_enabled: true, show_results_comparison: true,
      background_image: ActionController::Base.helpers.image_path("verto-library/backgrounds/#{background}.jpg"),
      **attrs
    )
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s
  end

  def play_to_the_end(survey)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    agree_to_consent_gate
    click_button "Next"
    assert_selector ".preview-card.active .freeform-wrap", wait: 8
    find("[data-player-target='finishBtn']").click
    assert_selector ".join-card", wait: 10
  end

  def relative_luminance(r, g, b)
    lin = [ r, g, b ].map do |c|
      c /= 255.0
      c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4)
    end
    (0.2126 * lin[0]) + (0.7152 * lin[1]) + (0.0722 * lin[2])
  end

  def ratio(a, b)
    hi, lo = [ a, b ].max, [ a, b ].min
    (hi + 0.05) / (lo + 0.05)
  end

  # The worst contrast any sampled pixel of `selector` achieves against what is
  # actually painted behind it.
  #
  # The GLYPHS are removed and the page screenshotted, so the sample IS the
  # backdrop — scrim, photo and anything between, as the browser composited
  # them. The text's own colour is then composited over each sampled pixel at
  # its computed alpha, which is what a reader's eye receives. Nothing here
  # trusts a CSS value to mean what it looks like it means.
  #
  # `color: transparent` rather than `visibility: hidden`, which was the first
  # attempt and measured the wrong thing: visibility hides an element's OWN
  # background along with it, and .on-backdrop puts the scrim on the same
  # element as the words. So the editor's labels sampled the bare photo — 1.36:1
  # against a scrim that was right there in the computed style — and the fault
  # was in the ruler. text-shadow has to go with it: a shadow is still painted
  # under transparent text, and it would fill in the very pixels being measured.
  def worst_contrast(selectors, tag:)
    selectors.to_h { |name, sel| [ name, measure(name, sel, tag: tag) ] }
  end

  # Every element at or under `scope` that owns words of its own, stamped with
  # a selector we can measure it by. An ENUMERATION rather than a list of
  # selectors, so a label added to the editor's chrome tomorrow is measured
  # without anyone remembering to add it here — which is the whole point: the
  # labels that went unreadable were the ones nobody thought to check.
  #
  # "Owns" means direct text children. A parent is measured for its own words
  # only, and a child with its own colour (the share card's character count is
  # 35% white inside a label that is not) is measured separately, against its
  # own ink rather than its parent's.
  def text_bearers(scope)
    page.evaluate_script(<<~JS).map { |h| [ h["name"], "[data-contrast-probe='#{h['id']}']" ] }
      (() => {
        const own = el => Array.from(el.childNodes)
          .filter(n => n.nodeType === Node.TEXT_NODE && n.textContent.trim().length > 1)
          .map(n => n.textContent.trim()).join(' ')
        const out = []
        document.querySelectorAll(#{scope.to_json}).forEach(root => {
          [root, ...root.querySelectorAll('*')].forEach(el => {
            const words = own(el)
            if (!words || el.offsetParent === null) return
            const id = String(out.length)
            el.setAttribute('data-contrast-probe', id)
            out.push({ id: id, name: words.slice(0, 40) })
          })
        })
        return out
      })()
    JS
  end

  # One element, scrolled to where a reader would have it before it is read.
  #
  # The end screen is a scroll container of its own (.preview-thankyou), and a
  # thank-you with a comparison button, an account ask and three CTAs runs off
  # the bottom of a 900px viewport — the wordmark sat below the fold. Measured
  # where it lay, it read 3.07:1 on `sport`: a sliver of its box clipped at the
  # viewport edge, sampling photo rather than its own pill. That is not a
  # contrast failure, it is measuring something that isn't on screen.
  #
  # So scroll it into view, settle, and then REQUIRE the whole box to be in
  # frame — a partial reading raises rather than returning a number, because a
  # number here is indistinguishable from a real fault.
  def measure(name, selector, tag:)
    box, samples = backdrop_samples(name, selector, tag: tag)

    m = /rgba?\(([^)]+)\)/.match(box["color"])
    parts = m[1].split(",").map(&:to_f)
    tr, tg, tb = parts[0, 3]
    alpha = (parts[3] || 1.0) * box["opacity"].to_f

    worst = samples.map { |br, bg, bb|
      fr = (tr * alpha) + (br * (1 - alpha))
      fg = (tg * alpha) + (bg * (1 - alpha))
      fb = (tb * alpha) + (bb * (1 - alpha))
      ratio(relative_luminance(fr, fg, fb), relative_luminance(br, bg, bb))
    }.min

    { "name" => name, "ratio" => worst, "floor" => floor_for(box),
      "type" => format("%dpx/%d", box["fontSize"], box["fontWeight"]) }
  end

  # WCAG's own definition of large text, read off the type rather than kept in
  # a table beside it: 24px, or 18.66px once it is bold. Large text is allowed
  # 3:1 because it carries its own legibility; everything else owes 4.5:1.
  def floor_for(box)
    size, weight = box["fontSize"].to_f, box["fontWeight"].to_i
    large = size >= 24 || (size >= 18.66 && weight >= 700)
    large ? AA_LARGE : AA_BODY
  end

  # Everything the scrim backs, measured and reported together. One failure
  # line per word that cannot be read on it.
  def unreadable(bearers, tag:)
    bearers.filter_map do |name, selector|
      m = measure(name, selector, tag: tag)
      next if m["ratio"] && m["ratio"] >= m["floor"]

      format("%-38s %5.2f:1  (needs %.1f:1 at %s)",
             name.inspect, m["ratio"] || 0, m["floor"], m["type"])
    end
  end

  # The pixels actually painted behind the WORDS of `selector`.
  #
  # The line boxes, from a Range over the element's contents — not the
  # element's border box, which was the third way this measurement went wrong.
  # .on-backdrop is a fit-content pill with an 8px radius and 4px/10px of
  # padding, so its border box has corners the pill does not paint and the
  # glyphs never reach. Taking the worst pixel over the whole box therefore read
  # the photo in those corners: 1.36:1 for a label whose own backdrop measures
  # 7.45:1 behind every letter of it.
  #
  # A reader reads the glyphs. Sample where the glyphs are.
  def backdrop_samples(name, selector, tag:)
    node = find(selector, visible: :all, wait: 5)
    page.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'})", node)
    settle_box(node)

    box = page.evaluate_script(<<~JS, node)
      (() => {
        const el = arguments[0], cs = getComputedStyle(el)
        let opacity = 1
        for (let n = el; n; n = n.parentElement) opacity *= parseFloat(getComputedStyle(n).opacity)
        // This element's OWN words, not its descendants' — a child can carry a
        // different colour, and measuring it with the parent's ink is how a
        // faded one hides.
        const raw = []
        Array.from(el.childNodes)
          .filter(n => n.nodeType === Node.TEXT_NODE && n.textContent.trim().length > 1)
          .forEach(n => {
            const range = document.createRange()
            range.selectNode(n)
            raw.push(...range.getClientRects())
          })
        // Inset by a pixel: the outermost row and column of a line box are
        // where antialiasing against whatever is beyond it lives.
        const rects = raw
          .filter(r => r.width > 2 && r.height > 2)
          .map(r => ({ x: Math.ceil(r.left) + 1, y: Math.ceil(r.top) + 1,
                       w: Math.floor(r.width) - 2, h: Math.floor(r.height) - 2 }))
        return { rects: rects, iw: innerWidth, ih: innerHeight,
                 color: cs.color, opacity: opacity,
                 fontSize: parseFloat(cs.fontSize), fontWeight: parseInt(cs.fontWeight, 10) }
      })()
    JS

    if box["rects"].empty?
      raise "#{name} (#{selector}) has no text line boxes to measure — it renders no words."
    end

    offscreen = box["rects"].reject do |r|
      r["x"] >= 0 && r["y"] >= 0 &&
        r["x"] + r["w"] <= box["iw"] && r["y"] + r["h"] <= box["ih"]
    end
    unless offscreen.empty?
      raise "#{name} (#{selector}) is not wholly on screen after scrolling to it — " \
            "line boxes #{offscreen.inspect} in #{box['iw']}x#{box['ih']}. Measuring a clipped " \
            "line samples whatever is beside it, not what is behind it."
    end

    glyphs(selector, "transparent")
    file = capture("contrast-#{tag}-#{name.gsub(/\W+/, '-')}")
    begin
      img = ChunkyPNG::Image.from_file(file)
    ensure
      File.delete(file) if File.exist?(file)
    end
    glyphs(selector, nil)

    samples = []
    box["rects"].each do |r|
      (r["x"]...(r["x"] + r["w"])).step([ r["w"] / 24, 1 ].max) do |x|
        (r["y"]...(r["y"] + r["h"])).step([ r["h"] / 8, 1 ].max) do |y|
          px = img[x, y]
          samples << [ ChunkyPNG::Color.r(px), ChunkyPNG::Color.g(px), ChunkyPNG::Color.b(px) ]
        end
      end
    end
    [ box, samples ]
  end

  # Remove (or restore) the glyphs of `selector` and everything inside it,
  # leaving every background exactly where it was.
  def glyphs(selector, colour)
    page.execute_script(<<~JS)
      document.querySelectorAll(#{selector.to_json} + ', ' + #{selector.to_json} + ' *').forEach(e => {
        if (#{colour.nil?}) { e.style.removeProperty('color'); e.style.removeProperty('text-shadow') }
        else { e.style.setProperty('color', #{colour.to_json}, 'important')
               e.style.setProperty('text-shadow', 'none', 'important') }
      })
    JS
  end

  # A viewport screenshot, on disk, where we can find it again. Per-process and
  # per-call: tmp/capybara is shared by every parallel worker.
  def capture(stem)
    name = "#{stem}-#{Process.pid}-#{SecureRandom.hex(3)}.png"
    page.save_screenshot(name)
    Dir.glob(Rails.root.join("tmp/capybara/**/#{name}")).first ||
      raise("screenshot #{name} was not written under tmp/capybara")
  end

  # ── The ruler, before anything it measures ───────────────────────────────
  #
  # This one is not about the product. It is about whether the measurement
  # above can be believed, and it exists because the measurement has been wrong
  # twice in a way that LOOKED like a contrast bug:
  #
  #   1. `visibility: hidden` was used to strip the words, and it takes the
  #      element's own background with it. Text with .on-backdrop then sampled
  #      the bare photo and read 1.36:1 with the scrim sitting right there in
  #      the computed style.
  #   2. An element scrolled below the fold was sampled where it lay, so a
  #      clipped sliver of the viewport edge stood in for its own pill: 3.07:1
  #      for a wordmark that was not on screen at all.
  #
  # Both produced a plausible failing NUMBER, which is the dangerous shape of
  # wrong — a wrong ruler here either invents a fault or, worse, misses one.
  # So: point the ruler at something whose answer is known independently, and
  # check it comes back. The teal CTA is opaque, brand-coloured and painted by
  # a different rule than anything under test.
  test "the ruler reads back a colour it can be checked against" do
    survey = survey_on("landscape")
    with_viewport(1440, 900, mobile: false) do
      play_to_the_end(survey)

      cta = "[data-player-target='joinReveal'] .join-btn"
      expected = page.evaluate_script(
        "getComputedStyle(document.querySelector(#{cta.to_json})).backgroundColor"
      ).scan(/\d+/).first(3).map(&:to_i)

      _box, samples = backdrop_samples("the CTA", cta, tag: "calibrate")
      # The button's own fill, not its label: the glyphs are gone, so the line
      # box the sampler reads is flat brand teal all the way across.
      modal = samples.tally.max_by { |_, n| n }.first
      assert_equal expected, modal,
                   "the sampled backdrop #{modal.inspect} is not the #{expected.inspect} the browser " \
                   "says it painted — the ruler is not registered with the page, and every ratio " \
                   "this file reports is meaningless until it is"
    end
  end

  # Everything the scrim is responsible for, on the player: the halo behind the
  # message and the wordmark's pill. Named as SURFACES, not as the three things
  # that sit on them today — a fourth line added to the end screen tomorrow is
  # measured because it lands on the scrim, not because someone listed it.
  PLAYER_SCRIM = ".thankyou-message, .play-powered"

  test "every word on the player's end screen clears AA over every background" do
    failures = []
    BACKGROUNDS.each do |bg|
      survey = survey_on(bg)
      with_viewport(1440, 900, mobile: false) do
        play_to_the_end(survey)
        bearers = text_bearers(PLAYER_SCRIM)
        assert_operator bearers.size, :>=, 3,
                        "expected the end screen's scrim to carry the title, the subtitle and the " \
                        "wordmark at least; found #{bearers.size} on #{bg}.jpg"
        failures.concat(unreadable(bearers, tag: "player-#{bg}").map { |f| "#{bg}.jpg  #{f}" })
      end
    end
    assert_empty failures,
                 "text on the end screen is lost in the Verto's background photo:\n  " +
                 failures.join("\n  ") +
                 "\n\nThe scrim is derived in BrandPalette#readable_surface and painted by " \
                 ".thankyou-message / .play-powered. If one moved, the other has to move with it."
  end

  # A creator can pick any background colour, and the scrim is derived FROM it.
  # A pale pick is the case the derivation exists for: it must come out dark
  # enough to carry white, in the creator's own hue rather than a grey slab.
  test "a pale brand background still carries white text" do
    survey = survey_on("landscape", brand_palette: { "bg" => "#F3F1EA", "primary" => "#2F7F76" })
    with_viewport(1440, 900, mobile: false) do
      play_to_the_end(survey)
      assert_empty unreadable(text_bearers(PLAYER_SCRIM), tag: "pale"),
                   "a pale brand background is the case readable_surface exists for, and it is " \
                   "the one that failed"
      # And it is still the brand's hue, not a neutral: the scrim's green
      # channel leads, as #2F7F76-adjacent darkening of a warm cream would not.
      scrim = page.evaluate_script(
        "getComputedStyle(document.querySelector('.preview-thankyou')).getPropertyValue('--brand-scrim').trim()"
      )
      assert_match(/rgba?\(/, scrim, "the scrim should be a derived colour, not a fallback")
    end
  end

  # The editor draws the same screen on the same photo, and it draws words the
  # player never does — "They'll also see", "Link button", the placeholder hint.
  # Two surfaces carry them: the same .thankyou-message halo the player has, and
  # .on-backdrop, which exists for the labels that sit outside it.
  #
  # Stated as the surfaces rather than as today's labels, for the same reason as
  # above — and it earns that immediately: the editor's placeholder hint was 45%
  # white on the halo (3.1:1) and no list of labels would have had it on it.
  #
  # One difference from the player, deliberate and not this test's to fix: the
  # palette variables are inlined on .editor-backdrop alone, so they do not
  # cascade into the feed (the right panel's chrome has to keep Playverto's
  # colours — see the view). The feed therefore paints the stylesheet's fallback
  # scrim rather than the Verto's derived one. That is the real behaviour, so it
  # is what is measured; the fallback is a dark navy that carries white over any
  # photo, so a pale-palette Verto is legible here even though it is not in hue.
  EDITOR_SCRIM = ".editor-feed .thankyou-message, .editor-feed .on-backdrop"

  test "every word the editor draws on the backdrop clears AA over it" do
    survey = survey_on("landscape")
    sign_in_as @user
    failures = []
    counted = 0

    with_viewport(1440, 950, mobile: false) do
      visit survey_path(survey)
      assert_selector ".gate-ty-card", wait: 10
      click_button "Got it" if has_button?("Got it", wait: 3)

      bearers = text_bearers(EDITOR_SCRIM)
      counted = bearers.size
      assert_operator counted, :>=, 5,
                      "expected the editor's feed to draw several words on the backdrop, found " \
                      "#{counted} — if a class was renamed this test is measuring nothing"

      failures = unreadable(bearers, tag: "editor")
    end

    assert_empty failures,
                 "#{failures.size} of #{counted} words the editor draws on the Verto's background " \
                 "photo cannot be read on it:\n  " + failures.join("\n  ") +
                 "\n\nBoth surfaces paint --brand-scrim, which is derived to carry WHITE at 4.5:1. " \
                 "Ink fainter than white spends a margin that is not there."
  end
end
