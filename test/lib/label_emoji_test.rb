require "test_helper"

# The extraction rules for hoisting an option label's emoji into its icon tile.
# Table-driven because the interesting part is the boundary cases: what counts
# as one emoji, what must never be torn off a legitimate label, and when to
# leave a label alone entirely.
class LabelEmojiTest < ActiveSupport::TestCase
  # [input, expected_glyphs, expected_text, why]
  CASES = [
    # ── the everyday shapes ────────────────────────────────────────────────
    [ "🎯 Pay off debt", "🎯", "Pay off debt", "leading emoji, the generated-deck default" ],
    [ "Pay off debt 🎯", "🎯", "Pay off debt", "trailing emoji" ],
    [ "🎯Pay off debt",  "🎯", "Pay off debt", "no separating space" ],
    [ "🎯 Pay off debt", "🎯", "Pay off debt", "non-breaking space separator" ],
    [ "🔥 Start saving 🎯", "🔥", "Start saving 🎯", "leading wins; the trailing one stays inline" ],
    [ "Pay off debt", nil, "Pay off debt", "nothing to hoist" ],
    [ "  🎯  Pay off debt  ", "🎯", "Pay off debt", "outer whitespace trimmed" ],

    # ── one glyph, several codepoints ──────────────────────────────────────
    [ "👍🏽 Agree", "👍🏽", "Agree", "skin-tone modifier is part of the cluster" ],
    [ "👨‍👩‍👧 Family", "👨‍👩‍👧", "Family", "ZWJ sequence is ONE emoji, never split" ],
    [ "🇬🇧 United Kingdom", "🇬🇧", "United Kingdom", "flag is a regional-indicator pair" ],
    [ "❤️ Health", "❤️", "Health", "variation selector absorbed" ],
    [ "1️⃣ First choice", "1️⃣", "First choice", "keycap sequence" ],

    # ── runs ───────────────────────────────────────────────────────────────
    [ "🎯🔥 Pay off debt", "🎯🔥", "Pay off debt", "a short run hoists whole" ],
    [ "🎉🎊✨ Party", "🎉🎊✨", "Party", "three is the limit" ],
    [ "🎉🎊✨🥳 Party", nil, "🎉🎊✨🥳 Party", "four is decoration, not an icon — leave it" ],

    # ── things that must NOT be treated as emoji ───────────────────────────
    [ "© Copyright notice", nil, "© Copyright notice", "bare © is text, not an icon" ],
    [ "→ Next step", nil, "→ Next step", "bare arrow is punctuation" ],
    [ "1. Option A", nil, "1. Option A", "a digit alone is not a keycap" ],
    [ "▪ Bullet point", nil, "▪ Bullet point", "bare geometric shape is text" ],
    [ "日本語、はい", nil, "日本語、はい", "CJK punctuation is left alone" ],
    [ "نعم، أوافق", nil, "نعم، أوافق", "RTL label untouched" ],

    # ── refuse to blank a label ────────────────────────────────────────────
    [ "🎯", nil, "🎯", "emoji-only label stays — an empty label would be dropped on save" ],
    [ "🎯 🔥", nil, "🎯 🔥", "emoji-only, separated" ],
    [ "", nil, "", "blank" ]
  ].freeze

  CASES.each do |input, glyphs, text, why|
    test "split(#{input.inspect}) — #{why}" do
      got_glyphs, got_text = LabelEmoji.split(input)
      if glyphs.nil?
        assert_nil got_glyphs, "expected nothing to hoist out of #{input.inspect}"
      else
        assert_equal glyphs, got_glyphs, "glyphs for #{input.inspect}"
      end
      assert_equal text, got_text, "text for #{input.inspect}"
    end
  end

  test "a hoist never invents or loses characters" do
    CASES.each do |input, glyphs, text, _why|
      next if glyphs.nil?
      # Order differs for a trailing hoist, so compare as multisets.
      assert_equal LabelEmoji.trim(input).gsub(/[[:space:]]+/, "").chars.sort,
                   "#{glyphs}#{text}".gsub(/[[:space:]]+/, "").chars.sort,
                   "hoisting #{input.inspect} must not invent or lose characters"
    end
  end

  test "nil and non-string input are handled like blanks" do
    assert_equal [ nil, "" ], LabelEmoji.split(nil)
    assert_equal [ nil, "" ], LabelEmoji.split("   ")
    assert_equal [ nil, "42" ], LabelEmoji.split(42)
  end

  # One emoji per option: after a hoist the label has nothing left to offer.
  # The exception is a label emoji-topped at BOTH ends — the trailing one is
  # deliberately left inline, and Survey#hoist_option_label_emoji then leaves
  # the label alone forever after (it only strips when it is also promoting),
  # so the deck settles after a single pass either way.
  test "a hoisted label has nothing left to hoist" do
    CASES.each do |input, glyphs, _text, _why|
      next if glyphs.nil? || input == "🔥 Start saving 🎯"
      _, once = LabelEmoji.split(input)
      twice_glyphs, twice = LabelEmoji.split(once)
      assert_nil twice_glyphs, "#{input.inspect} still offers an emoji after one hoist"
      assert_equal once, twice
    end
  end

  test "words? tells an emoji-only label from one with real text" do
    assert LabelEmoji.words?("Pay off debt")
    assert LabelEmoji.words?("🎯 Pay off debt")
    refute LabelEmoji.words?("🎯")
    refute LabelEmoji.words?("🎯 🔥")
    refute LabelEmoji.words?("   ")
  end

  test "cluster_count treats multi-codepoint emoji as one" do
    assert_equal 1, LabelEmoji.cluster_count("👨‍👩‍👧")
    assert_equal 1, LabelEmoji.cluster_count("🇬🇧")
    assert_equal 1, LabelEmoji.cluster_count("👍🏽")
    assert_equal 3, LabelEmoji.cluster_count("🎉🎊✨")
  end
end
