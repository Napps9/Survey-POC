require "test_helper"

# The editor's phone/tablet frame and the live player's phone layout are ONE
# design stated twice, and they have to be stated twice.
#
# The player's mobile rules live inside a three-clause media query — "where the
# PLAYER stops being a desktop split-card" — that asks about the VIEWPORT. The
# editor's frame is a 390px box on a desktop-width page, so that query is false
# there and always will be: there is no viewport to match, only a bezel. Short
# of rendering the feed in an iframe (which would cost inline editing, the whole
# point of previewing in the editor) the frame has to restate the rules.
#
# Restating them is how they drift, and drift here is the expensive kind: the
# creator designs against a phone that does not exist, and finds out after
# publishing. The frame's block used to hold a flat 28% hero on every card, a
# fixed 24px pad and none of the player's per-type structure — which is exactly
# what this test now refuses to let happen again.
#
# Same crude-regex trade-off as player_hero_css_test, and the same excuse: this
# names causes that a browser test can only catch as symptoms.
class DeviceFrameParityTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/tailwind/application.css").freeze

  # The media whose presence earns a card a hero strip on a phone, and the
  # answer widgets that take the card back off it. Both lists are stated in the
  # player's mobile block; both must be stated in the frame's.
  HERO_MEDIA  = %w[.split-left-img .split-left-video .card-lottie .nps-lottie .has-media-bg].freeze
  HERO_OFF    = %w[.rotate-wrap .nps-slider .prioritise-list].freeze

  def css
    @css ||= File.read(CSS)
  end

  # Everything the device frames declare — from the block's first selector to
  # the .m-studio block, which is the next thing in the file that talks about
  # cards at phone size and is deliberately NOT part of this.
  def frame_block
    @frame_block ||= begin
      from = css.index(".device-tablet .split-card,")
      assert from, "the device-frame block is gone or its first selector was renamed"
      to = css.index("/* ── Text-size tiers", from)
      assert to, "the device-frame block no longer ends where this test expects"
      css[from...to]
    end
  end

  test "the frame states the same 45/55 split as every player tier" do
    pairs = frame_block.scan(
      /--play-hero-h:\s*clamp\([^,]+,\s*calc\(var\(--play-card-h\)\s*\*\s*([\d.]+)\).*?
       --play-right-min:\s*clamp\([^,]+,\s*calc\(var\(--play-card-h\)\s*\*\s*([\d.]+)\)/mx
    )

    assert_operator pairs.size, :>=, 2,
                    "expected the phone frame and the tablet frame each to state the pair as " \
                    "shares of --play-card-h — found #{pairs.size}. A frame that states a bare " \
                    "percentage instead is the 28% hero this replaced."
    pairs.each do |hero, right|
      assert_in_delta 0.45, hero.to_f, 0.001,
                      "a device frame gives the hero #{hero} of the card, not 0.45 — the creator " \
                      "is designing against a phone the player does not draw"
      assert_in_delta 1.0, hero.to_f + right.to_f, 0.001,
                      "a frame's two shares come to #{hero.to_f + right.to_f}, not 1"
    end
  end

  # The frame has no viewport of its own, so every token the player writes in
  # vw/svh has to be rewritten against --device-w/--device-h. A leftover vw here
  # measures the BROWSER WINDOW — a 5vw pad on a 1440px screen is 72px inside a
  # 390px phone, which is most of the card.
  test "the frame sizes itself off the device, never off the browser window" do
    offenders = frame_block.scan(/^\s*(--play-[\w-]+):\s*([^;]*(?:\d(?:vw|vh|svh|dvh))[^;]*);/)

    assert_empty offenders,
                 "a device-frame token is still measured against the real viewport: " \
                 "#{offenders.map { |k, v| "#{k}: #{v.strip}" }.join(', ')}. Inside the frame " \
                 "the viewport is the bezel — state it as a fraction of --device-w/--device-h."
  end

  test "the frame reads the player's tokens rather than restating their values" do
    %w[--play-hero-h --play-right-min --play-pad-x --play-pad-y --play-gap
       --play-bar-clear --play-lip --play-eyebrow --play-title --play-label].each do |token|
      assert_includes frame_block, "var(#{token})",
                      "the device frame declares #{token} and never reads it, or reads a hard " \
                      "number in its place — the token is what keeps the two blocks one design"
    end
  end

  test "the frame gives a hero to exactly the media the player does" do
    strip = frame_block[/((?:^\.device-[\w-]+ \.split-card:has\([^)]*\)\s+\.split-left,?\s*)+)\{[^}]*height:\s*var\(--play-hero-h\)[^}]*\}/m, 1]
    assert strip, "the frame's hero-strip rule is gone or reshaped past recognition"

    HERO_MEDIA.each do |cls|
      %w[device-tablet device-mobile].each do |frame|
        assert_includes strip, ".#{frame} .split-card:has(#{cls})",
                        "#{cls} earns a hero strip on a real phone but not in the #{frame} " \
                        "frame — its inset:0 element will position against the whole card"
      end
    end
  end

  # `contents`, never `none`: .panel-progress is markup INSIDE .split-left, so
  # `none` takes the progress bar out with the picture. The player's block makes
  # this point twice; the frame gets it wrong in exactly the same way.
  test "the frame drops a hero with contents, not none" do
    # `\.split-left\b` is not enough — `-` is a word character's neighbour here,
    # so .split-left-design-prompt-sub { display: none } matched and read as the
    # frame hiding a hero strip. The class has to END: a comma, a brace or
    # whitespace, never a hyphen.
    bodies = frame_block.scan(/\.device-mobile \.split-left(?![\w-])[^{]*\{([^}]*)\}/m).flatten +
             frame_block.scan(/\.device-mobile \.split-card:has\([^)]*\) \.split-left(?![\w-])\s*[^{]*\{([^}]*)\}/m).flatten
    dropped = bodies.select { |b| b =~ /display:\s*(contents|none)/ }

    assert dropped.any?, "the mobile frame no longer drops the hero strip for any card at all"
    dropped.each do |body|
      assert_match(/display:\s*contents/, body,
                   "the frame drops a hero strip with `display: none`, which hides " \
                   ".panel-progress along with the picture — the bar is markup inside the panel " \
                   "being dropped")
    end
  end

  test "the types that take the card back are the same three, and land last" do
    off = ".split-card:has(#{HERO_OFF.join(', ')}) .split-left"
    assert_includes frame_block, ".device-mobile #{off}",
                    "a type that drops its hero on a real phone keeps one in the editor frame " \
                    "(or the list has been retuned on one side only)"

    # Equal specificity, so source order is the only thing deciding it — the
    # same trap the player's own block carries a comment about.
    strip_at = frame_block.index("height: var(--play-hero-h)")
    off_at   = frame_block.index(".device-mobile #{off}")
    assert_operator off_at, :>, strip_at,
                    "the hero-off rule now sits ABOVE the strip rule. They are the same " \
                    "specificity, so the strip wins and an NPS or tap card gets a hero the " \
                    "player does not give it."
  end

  # A finger is the only input the frame is showing, and these come from the
  # phone media query, so at desktop width they simply did not apply: the frame
  # drew a 33px option row where the phone draws 44.
  test "the frame shows touch-sized targets" do
    assert_match(/\.device-mobile \.pick-item[^{]*\{[^}]*min-height:\s*44px/m, frame_block,
                 "option rows in the phone frame are not at the 44px touch minimum")
    assert_match(/\.device-mobile \.rating-wrap\s*\{[^}]*--rating-star-size:\s*56px/m, frame_block,
                 "the star row in the phone frame is not at the size a phone draws it")
  end
end
