require "test_helper"

# Every question type carries a brand hue.
#
# Ask Verto paints a citation chip with the accent of the question type it cites,
# so a type with no accent produces a chip that says less than its neighbours —
# and because the fallback is silent, nobody would notice until a customer asked
# why one source looks different. This fails the build instead.
class CardTypesAccentTest < ActiveSupport::TestCase
  HEX = /\A#[0-9A-Fa-f]{6}\z/

  test "every card type declares a valid hex accent" do
    missing = CardTypes.all.reject { |_key, attrs| attrs["accent"].to_s.match?(HEX) }

    assert_empty missing.map(&:first),
      "card types with no accent in config/card_types.yml: #{missing.map(&:first).join(", ")}"
  end

  test "accents come from the palette the results screen already uses" do
    # Not an arbitrary allow-list — these are the brand hues the app already
    # assigns to question families (left_bg_for in surveys/results.html.erb and
    # the .sb-* badges). A new accent outside this set means someone has
    # introduced a colour, which is a design decision, not a config tweak.
    allowed = %w[#615BF5 #8B85FF #0CA7FF #FFCC00 #FF1E6F #01EACB #FFC24B].to_set

    CardTypes.all.each do |key, attrs|
      assert_includes allowed, attrs["accent"], "#{key} uses a colour outside the brand set"
    end
  end

  test "the open-text family is distinguishable from the choice family" do
    # The one distinction that carries real meaning in an answer: a quote and a
    # percentage must not look alike.
    assert_not_equal CardTypes.accent("open_ended"), CardTypes.accent("multiple_choice")
  end

  test "accent falls back rather than raising for an unknown type" do
    assert_equal CardTypes::ACCENT_FALLBACK, CardTypes.accent("something_new")
    assert_equal "◆", CardTypes.icon("something_new")
  end

  test "accent_soft derives an rgba wash from the same hex" do
    assert_equal "rgba(255, 30, 111, 0.14)", CardTypes.accent_soft("open_ended")
    assert_equal "rgba(255, 30, 111, 0.4)", CardTypes.accent_soft("open_ended", 0.4)
  end

  test "every indexable Ask Verto type has an icon to render" do
    CorpusIndexer::INDEXABLE_TYPES.each do |type|
      assert CardTypes.icon(type).present?, "#{type} has no picker_icon"
    end
  end
end
