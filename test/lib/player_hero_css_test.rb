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
  #
  # The tiers used to state the pair as viewport fractions, 40svh against
  # 50svh, and that ratio is 44.4 rather than 45 — the difference was supposed
  # to reach the hero through the flex-grow inversion and never did, because the
  # hero stops at its own cap. Measured 44.0% on every image card. Worse on the
  # short viewports, and in the other direction: where the footer hits its 56px
  # floor, 45% of the card is 39.7svh, which no single viewport fraction can
  # say. So the shares are now taken from --play-card-h, which is the card
  # itself, and 45/55 is stated literally instead of approximated.
  # The three types that drop their mobile hero strip — tap matrix, NPS and
  # prioritise — all do it with `display: contents`, and the value is the whole
  # trick. .panel-progress is markup INSIDE .split-left, so `none` takes the
  # progress bar out with the picture, and a respondent loses their sense of
  # how far through they are on exactly the cards that take longest.
  # `contents` drops the box and keeps the children.
  #
  # hero_promise_test holds both halves in a browser. This names the value,
  # because `none` is what anyone tidying up would write and the symptom — a
  # missing 4px bar — is easy to miss on a screenshot.
  test "every type that drops its hero strip drops it with contents, not none" do
    [ ".rotate-wrap", ".nps-slider", ".prioritise-list" ].each do |hook|
      bodies = rule_bodies(".preview-overlay .split-card:has(#{hook}) .split-left")

      assert bodies.any?, "no rule drops the hero strip for #{hook} at all"
      assert bodies.any? { |b| b =~ /display:\s*contents/ },
             "#{hook} drops its hero strip with something other than `display: contents` " \
             "(#{bodies.map(&:strip).inspect}). Any of none/height:0/visibility:hidden hides " \
             ".panel-progress along with the picture, because the bar is markup inside the " \
             "panel being hidden."
    end
  end

  # Specificity is equal here, so SOURCE ORDER is the only thing deciding it.
  # The media reset gives a card with a photo its ordinary top pad, because the
  # bar rides the photo. The contents-branches then take it back, because they
  # drop the photo's strip even when the card carries one — so their bar is on
  # the panel after all. Both selectors are (0,4,0); put them the wrong way
  # round and a prioritise or NPS card WITH an image gets its progress bar
  # under the eyebrow, on that card type only, in the mobile block only.
  test "the bar clearance is re-asserted after the media reset, not before it" do
    media = css.index(".preview-overlay .split-card:has(.split-left-img, .split-left-video, .card-lottie) .split-right")
    clear = css.index(".preview-overlay .split-card:has(.rotate-wrap, .nps-slider, .prioritise-list) .split-right")

    assert media, "the media pad reset is gone"
    assert clear, "the bar-clearance re-assert is gone, or a type has dropped off its list — " \
                  "every contents-branch type has to be on it"
    assert_operator clear, :>, media,
                    "the bar-clearance rule now sits ABOVE the media reset in the file. They " \
                    "are the same specificity, so the reset wins and every hero-less card " \
                    "carrying an image loses its progress-bar clearance."

    body = rule_bodies(".preview-overlay .split-card:has(.rotate-wrap, .nps-slider, .prioritise-list) .split-right").first
    assert_match(/padding-top:\s*var\(--play-bar-clear\)/, body,
                 "the re-assert no longer sets --play-bar-clear, so it is a no-op rule")
  end

  # The clearance is a padding, and a padding is only half the distance between
  # the bar and the first line of the panel — the other half is where the panel
  # STARTS, and the lip rule moves that. It matches on :has(.split-left-img),
  # which these three types satisfy: they drop the hero STRIP, not the hero's
  # markup. So a tap, NPS or prioritise card carrying a photo was pulled 22px
  # (--play-lip) up into the 28px it had just been given to clear, and the
  # progress fill sheared "TAP TO RESPOND" mid-letter — the same symptom the
  # padding was added for, on the one variant the padding does not fix.
  #
  # A lip is the panel riding the bottom edge of a hero strip. These types have
  # no strip, so there is no edge and nothing to round over. hero_promise_test
  # measures the result in a browser; this names the two properties, because
  # what went wrong is invisible in the rule that looks wrong.
  test "the types that drop the hero strip drop its lip with it" do
    body = rule_bodies(".preview-overlay .split-card:has(.rotate-wrap, .nps-slider, .prioritise-list) .split-right").first
    lip  = css.index(".preview-overlay .split-card:has(.split-left-img)   .split-right")
    reset = css.index(".preview-overlay .split-card:has(.rotate-wrap, .nps-slider, .prioritise-list) .split-right")

    assert lip, "the hero lip rule is gone, or its selector no longer leads the list"
    assert_operator reset, :>, lip,
                    "the lip reset now sits ABOVE the lip itself. Both are (0,4,0), so the lip " \
                    "wins and a hero-less card carrying a photo is pulled back under its bar."
    assert_match(/margin-top:\s*0/, body,
                 "the re-assert no longer zeroes margin-top, so --play-lip still pulls these " \
                 "panels up under the progress bar on any card that carries an image")
    assert_match(/border-radius:\s*0/, body,
                 "the re-assert no longer zeroes border-radius: the panel keeps rounded top " \
                 "corners over a hero strip it does not have, and the card's own corners " \
                 "show through them")
  end

  test "the hero and the answer panel state one ratio, in every tier" do
    pairs = css.scan(
      /--play-hero-h:\s*clamp\([^,]+,\s*calc\(var\(--play-card-h\)\s*\*\s*([\d.]+)\).*?
       --play-right-min:\s*clamp\([^,]+,\s*calc\(var\(--play-card-h\)\s*\*\s*([\d.]+)\)/mx
    )

    assert_operator pairs.size, :>=, 3,
                    "expected the base, tablet-portrait and short-viewport tiers each to state " \
                    "the pair as shares of --play-card-h — found #{pairs.size}"
    pairs.each do |hero, right|
      assert_in_delta 0.45, hero.to_f, 0.001,
                      "a mobile tier gives the hero #{hero} of the card, not 0.45"
      assert_in_delta 1.0, hero.to_f + right.to_f, 0.001,
                      "a tier's two shares come to #{hero.to_f + right.to_f}, not 1. They are " \
                      "halves of one card; anything else means the pair has been retuned apart, " \
                      "which is the failure mode this pins."
    end
  end

  # The token those shares are taken from has to be defined whatever matched.
  # It lives on .preview-overlay OUTSIDE the phone media queries deliberately:
  # every tier that reads it sits on that same element, but a var() resolving to
  # nothing makes the whole calc invalid — which would void --play-hero-h and
  # collapse the card rather than degrade it. Cheap to state, expensive to
  # discover.
  test "the card height is defined outside any media query" do
    # Brace depth, not "before the first @media" — a top-level rule sits after
    # plenty of earlier media blocks, and the naive version of this test failed
    # on correct CSS for exactly that reason. Depth 1 is a bare rule; anything
    # deeper is nested inside an at-rule.
    stripped = css.gsub(%r{/\*.*?\*/}m, "")
    depth = 0
    depths = []
    stripped.each_line do |line|
      depths << depth if line.include?("--play-card-h:")
      depth += line.count("{") - line.count("}")
    end

    assert_includes depths, 1,
                    "--play-card-h is only declared inside an at-rule (found at brace " \
                    "depth #{depths.inspect}). Every tier's hero and answer-panel size is " \
                    "calc()'d from it, and an unresolved var() in a calc invalidates the " \
                    "whole declaration — so a viewport that misses that query gets no card " \
                    "layout at all, rather than a degraded one."
    assert_match(/--play-card-h:\s*calc\(100svh\s*-\s*clamp\(/, css,
                 "--play-card-h is no longer the viewport less the footer, which is the " \
                 "definition the 45/55 shares are taken against")

    refute_match(/--play-card-h:\s*calc\([^)]*\)\s*-\s*1px/, css,
                 "the footer's 1px rule is being subtracted twice — its min-height is a " \
                 "border-box measurement and already contains it. That cost 0.9px and landed " \
                 "the split on 44.9% instead of 45.0.")
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
