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

  test "the range strip grows from an auto height" do
    body = rule_bodies(".preview-overlay .split-card:has(.nps-lottie) .split-left")
             .find { |b| b.include?("flex: 1 1 auto") }

    assert body, "the range strip's grow rule is gone — the animation is back on a fixed clamp"
    assert_match(/height:\s*auto/, body,
                 "height: auto is the mechanism, not tidiness: the strip's children are all " \
                 "absolutely positioned, so only with an auto height does its flex base stay " \
                 "out of the card's intrinsic-height math. Put a fixed height back and short " \
                 "viewports scroll under a tall hero instead of shrinking it.")
  end

  test "the range answer panel is content-sized and unshrinkable" do
    bodies = rule_bodies(".preview-overlay .split-card:has(.nps-lottie) .split-right")
    body = bodies.find { |b| b.include?("flex") }

    assert body, "the range answer panel's rule is gone"
    assert_match(/flex:\s*0 0 auto/, body,
                 "flex-shrink must stay 0: .split-right is overflow:hidden, which zeroes its " \
                 "automatic minimum, so a shrinkable panel doesn't degrade — it clips the " \
                 "slider invisibly. An answer may cost a scroll; it may never cost a control.")
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
    strip_selector_block = css[/([^{}]*)\{[^}]*flex:\s*0 1 auto;\s*height:\s*var\(--play-hero-h\)[^}]*\}/m, 1]

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

  # The ladder's middle rung. Without it the hero's only verdicts are "45% of
  # the card" and "gone", and once the hero grew to 45% a handful of answers
  # started trading their picture away entirely to buy back a few dozen pixels
  # — measured, not hypothesised: a six-tile grid and a free-text card both
  # crossed that line on an iPhone 15.
  test "the shed ladder can slim the hero, not only remove it" do
    assert_match(/\.preview-card\.hero-slim .*\.split-left\s*\{[^}]*max-height:\s*var\(--play-hero-min\)/m,
                 css,
                 "hero-slim is gone or no longer caps the strip at --play-hero-min — the ladder " \
                 "is back to all-or-nothing and image cards with long answers lose their art " \
                 "outright instead of keeping a band of it.")
  end

  test "hero-off hides the range animation too" do
    hide_rule = css[/\.preview-overlay \.preview-card\.hero-off[^{]*\.card-lottie[^{]*\{[^}]*\}/m]

    assert hide_rule, "the hero-off hide list is gone or no longer covers .card-lottie"
    assert_includes hide_rule, ".nps-lottie",
                    ".nps-lottie is off the hero-off hide list again. Range never sheds " \
                    "today, but this was the one inset:0 element NOT hidden — the one that " \
                    "covers the whole card the day that stops being true."
  end
end
