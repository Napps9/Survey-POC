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

  # The matcher used to compare the WHOLE normalised label against the
  # catalogue, so a keyword only ever fired for a label that was nothing but
  # that keyword. Every option on a "how did you hear about us?" card fell
  # through to the coloured shapes — reported 18 Aug as "auto emoji picker only
  # picks these shapes… would be amazing if it could select a close match".
  test "a keyword inside a longer label matches" do
    assert_equal "📱", OptionIconLibrary.emoji_for("Social media")
    assert_equal "🗣️", OptionIconLibrary.emoji_for("Word of mouth")
    assert_equal "🔍", OptionIconLibrary.emoji_for("Online search")
    assert_equal "🎟️", OptionIconLibrary.emoji_for("Previous attendee")
  end

  # A leading article shouldn't hide an otherwise exact keyword.
  test "stopwords don't block a match" do
    assert_equal "👥", OptionIconLibrary.emoji_for("A colleague")
    assert_equal OptionIconLibrary.emoji_for("colleague"), OptionIconLibrary.emoji_for("The colleague")
  end

  # Longest run wins, so a two-word entry beats either of its halves.
  test "a longer keyword beats a shorter one inside the same label" do
    assert_equal "📰", OptionIconLibrary.emoji_for("Email newsletter"),
                 "'email newsletter' should win over the bare 'email'"
    refute_equal OptionIconLibrary.emoji_for("email"), OptionIconLibrary.emoji_for("Email newsletter")
  end

  # Some catalogue keys contain stopwords themselves; stripping stopwords before
  # trying the label as written would stop those keys ever matching.
  test "a catalogue key containing a stopword still matches its own label" do
    assert_equal "🏠", OptionIconLibrary.emoji_for("Buy a home")
  end

  # Being looser must not make it loose enough to be surprising: a label with no
  # catalogued subject still gets a neutral shape, not a bad guess.
  test "a label with nothing catalogued in it still falls back" do
    assert_includes OptionIconLibrary::EMOJI_FALLBACKS,
                    OptionIconLibrary.emoji_for("Zorbing on Tuesdays", 0)
  end
end
