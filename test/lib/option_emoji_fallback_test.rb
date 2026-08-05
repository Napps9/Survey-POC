require "test_helper"

# No selection answer should show an empty tile — a bare gradient reads as
# unfinished next to the rows that did match something.
class OptionEmojiFallbackTest < ActiveSupport::TestCase
  test "a curated keyword gets its emoji" do
    assert_equal "👍", OptionIconLibrary.emoji_for("Yes")
    assert_equal "👎", OptionIconLibrary.emoji_for("No")
    assert_equal "💳", OptionIconLibrary.emoji_for("Pay off debt")
    assert_equal "🏠", OptionIconLibrary.emoji_for("Buy a home")
  end

  test "matching normalises case, punctuation and plurals like the icon lookup" do
    assert_equal "🏦", OptionIconLibrary.emoji_for("  SAVINGS!  ")
    assert_equal "📈", OptionIconLibrary.emoji_for("Investments")
    assert_equal "🧾", OptionIconLibrary.emoji_for("Bills")
  end

  test "an unmatched label still gets an emoji, cycled by position" do
    a = OptionIconLibrary.emoji_for("Something nobody catalogued", 0)
    b = OptionIconLibrary.emoji_for("Another odd one", 1)

    assert a.present?, "every option must end up with something in its tile"
    assert b.present?
    refute_equal a, b, "neighbouring unmatched options should not look identical"
  end

  test "the fallback cycle is stable and wraps" do
    size = OptionIconLibrary::EMOJI_FALLBACKS.length
    assert_operator size, :>=, 2
    assert_equal OptionIconLibrary.emoji_for("zzz", 0), OptionIconLibrary.emoji_for("zzz", size)
    assert_equal OptionIconLibrary.emoji_for("zzz", 3), OptionIconLibrary.emoji_for("zzz", 3)
  end

  test "the catalogue is well formed" do
    OptionIconLibrary::EMOJI_KEYWORDS.each do |keyword, emoji|
      assert_equal keyword, OptionIconLibrary.normalize(keyword),
                   "#{keyword.inspect} won't ever match — it isn't in normalised form"
      assert emoji.present?, "#{keyword.inspect} has no emoji"
      assert_operator emoji.length, :<=, Survey::MAX_TOKEN_ICON,
                      "#{emoji} is longer than a tile can hold"
    end
  end
end
