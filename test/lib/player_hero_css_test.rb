require "test_helper"

# The load-bearing declarations of the range-hero inversion, pinned at source.
#
# The mobile player gives a range card's slider-reactive animation the height
# its answer doesn't need: the answer panel is content-sized and unshrinkable,
# the strip is the card's only grow item. Three of the declarations that make
# that work look EXACTLY like the kind of thing a tidy-up deletes — each one
# reads as redundant and each one is a different invisible failure when it
# goes. A browser test can catch the symptoms; this names the causes. Same
# crude-regex trade-off as player_safe_area_test, and the same excuse.
class PlayerHeroCssTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/tailwind/application.css").freeze

  def css
    @css ||= File.read(CSS)
  end

  def rule_bodies(selector)
    css.scan(/#{Regexp.escape(selector)}\s*\{([^}]*)\}/).flatten
  end

  test "the range strip grows from an auto height, and outranks the panel while doing it" do
    body = rule_bodies(".preview-overlay .split-card:has(.nps-lottie) .split-left")
             .find { |b| b =~ /flex:\s*\d+ 1 auto/ }

    assert body, "the range strip's grow rule is gone — the animation is back on a fixed clamp"
    assert_match(/height:\s*auto/, body,
                 "height: auto is the mechanism, not tidiness: the strip's children are all " \
                 "absolutely positioned, so only with an auto height does its flex base stay " \
                 "out of the card's intrinsic-height math. Put a fixed height back and short " \
                 "viewports scroll under a tall hero instead of shrinking it.")

    # The grow factor used to be a plain 1 and had nothing to compete with,
    # because the answer panel was flex-grow: 0. The panel grows now (the 189px
    # of white beneath it had to go somewhere), and flex divides free space in
    # PROPORTION to the factors — so two 1s handed the panel half the surplus
    # and took the hero from 341px to 259px on an iPhone 15. Measured, not
    # feared: that was the first attempt at this fix.
    #
    # A dominant factor is what restores the intended order — hero to its
    # --play-hero-h ceiling first, then the leftover to the panel. The number
    # is a priority, not a proportion, so pin that it is LARGE rather than
    # pinning a particular value.
    grow = body[/flex:\s*(\d+) 1 auto/, 1].to_i
    assert_operator grow, :>=, 100,
                    "the range strip's grow factor is #{grow}, close enough to the answer " \
                    "panel's 1 that they now share the surplus. The picture is supposed to " \
                    "have first claim on it and the panel is supposed to get only what the " \
                    "picture's ceiling won't let it take."
  end

  # Deliberately updated when the panel started growing (2026-08-21). What this
  # test protects is flex-SHRINK, and that has not moved; the grow factor is
  # the part that changed, on purpose, and is asserted here in its own right so
  # the pair can't drift apart unnoticed.
  test "the range answer panel grows into the leftover but never shrinks" do
    bodies = rule_bodies(".preview-overlay .split-card:has(.nps-lottie) .split-right")
    body = bodies.find { |b| b.include?("flex:") }

    assert body, "the range answer panel's rule is gone"
    assert_match(/flex:\s*1 0 auto/, body,
                 "flex-shrink must stay 0: .split-right is overflow:hidden, which zeroes its " \
                 "automatic minimum, so a shrinkable panel doesn't degrade — it clips the " \
                 "slider invisibly. An answer may cost a scroll; it may never cost a control. " \
                 "flex-grow must stay 1: at 0 the panel hugs its content and the height the " \
                 "hero's ceiling won't let it take is painted as .split-card's white " \
                 "background under the answer — 189px of it on an iPhone 15, which is the " \
                 "band the owner photographed on page 18 of the feedback sheet.")
    assert_match(/min-height:\s*0/, body,
                 "without min-height: 0 the base rule's --play-right-min (a 300-520px claim " \
                 "written for answers that scroll) still applies, and the blank void this " \
                 "change removed comes straight back as \"minimum\".")
  end

  test "every inset-0 hero medium is on the strip selector list" do
    # Video and pasted-Lottie cards fell off this list once: their inset:0
    # element then positioned against the whole .split-card — the Lottie
    # (z-index 1) covering the card, the video (z-index auto) hiding behind
    # the white panel and playing to nobody.
    # flex is 0 0 auto, not 0 1 auto: the strip stopped being shrinkable when the
    # header became a promise. Retiring the shed ladder alone did not deliver
    # that — the answer panel simply squeezed the hero instead, measured at 27.9%
    # of an iPhone 15 with no hero-off in sight. The shrink factor is the half
    # that makes 45% mean 45%.
    strip_selector_block = css[/([^{}]*)\{[^}]*flex:\s*0 0 auto;\s*height:\s*var\(--play-hero-h\)[^}]*\}/m, 1]

    assert strip_selector_block, "the hero-strip rule is gone or reshaped past recognition"
    %w[.split-left-img .split-left-video .card-lottie .nps-lottie].each do |cls|
      assert_includes strip_selector_block, ":has(#{cls})",
                      "#{cls} fell off the hero-strip selector list — its inset:0 element " \
                      "will position against the whole card on phones"
    end
  end

  # 45/55 is one number in two halves, and both halves are clamp() middles.
  # Retuning either alone is how the split silently stops being a split, and
  # the failure is invisible because each token on its own still reads as a
  # sensible number. So pin the RATIO, not the values — every mobile tier is
  # free to state it at whatever absolutes that tier can afford.
  test "the hero and the answer panel state one ratio, in every tier" do
    pairs = css.scan(
      /--play-hero-h:\s*clamp\([^,]+,\s*([\d.]+)svh.*?--play-right-min:\s*clamp\([^,]+,\s*([\d.]+)svh/m
    )

    assert_operator pairs.size, :>=, 3,
                    "expected the base, tablet-portrait and short-viewport tiers each to state " \
                    "the pair — found #{pairs.size}"
    pairs.each do |hero, right|
      share = hero.to_f / (hero.to_f + right.to_f)
      assert_in_delta 0.45, share, 0.01,
                      "a mobile tier splits the card #{(share * 100).round(1)}/" \
                      "#{((1 - share) * 100).round(1)}. The hero and the answer panel are tuned " \
                      "as a PAIR to 45/55 (the split the owner asked for); moving one without " \
                      "the other is the whole failure mode this pins."
    end
  end

  # The hero-slim test that used to sit here went with the class. It pinned the
  # shed ladder's middle rung — the band the hero shrank to before being given
  # up entirely — and there is no ladder to have a middle of any more: the
  # header holds its share and a long answer scrolls instead. hero-off survives
  # this, but for a different owner (see the test below and _watchTyping): it
  # is what drops the hero while a text field has focus, so the keyboard has
  # somewhere to go.

  test "hero-off hides the range animation too" do
    hide_rule = css[/\.preview-overlay \.preview-card\.hero-off[^{]*\.card-lottie[^{]*\{[^}]*\}/m]

    assert hide_rule, "the hero-off hide list is gone or no longer covers .card-lottie"
    assert_includes hide_rule, ".nps-lottie",
                    ".nps-lottie is off the hero-off hide list again. Range never sheds " \
                    "today, but this was the one inset:0 element NOT hidden — the one that " \
                    "covers the whole card the day that stops being true."
  end
end
