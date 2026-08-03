require "test_helper"

# Per-option visual overrides (`option_styles`) are client-supplied JSON, so
# the sanitiser is the contract: hex-validated colours, library-validated icon
# ids, clamped emoji, positional bounding — and nothing at all on card types
# that have no per-option tile to style.
class SurveyOptionStylesTest < ActiveSupport::TestCase
  def sanitize(card)
    Survey.sanitize_cards_images!([ card ]).first
  end

  def mc(styles, options: %w[a b c])
    { "type" => "multiple_choice", "text" => "Q", "options" => options, "option_styles" => styles }
  end

  test "a valid colour is normalised, an invalid one dropped" do
    c = sanitize(mc([ { "color" => "#AABBCC" }, { "color" => "red" }, nil ]))

    assert_equal "#aabbcc", c["option_styles"][0]["color"]
    assert_nil c["option_styles"][1], "an entry with nothing valid left collapses to null"
  end

  test "icon ids are validated against the library, emoji clamped like token icons" do
    c = sanitize(mc([ { "icon" => "basketball" }, { "icon" => "../../etc/passwd" }, { "emoji" => "🎯" * 10 } ]))

    assert_equal "basketball", c["option_styles"][0]["icon"]
    assert_nil c["option_styles"][1]
    assert_equal "🎯" * Survey::MAX_TOKEN_ICON, c["option_styles"][2]["emoji"]
  end

  test "the array is bounded to the option count and padded to keep positions" do
    c = sanitize(mc([ { "color" => "#112233" } ], options: %w[a b c]))
    assert_equal 3, c["option_styles"].length

    c = sanitize(mc([ nil, nil, nil, { "color" => "#112233" } ], options: %w[a b c]))
    refute c.key?("option_styles"),
           "a style past the last option is dropped, and nothing valid remains"
  end

  test "yes_no is bounded to its fixed pair" do
    c = sanitize({ "type" => "yes_no", "text" => "Q", "option_styles" => [ { "color" => "#112233" }, nil, { "color" => "#445566" } ] })
    assert_equal 2, c["option_styles"].length
  end

  test "an all-null array is deleted outright" do
    c = sanitize(mc([ nil, { "color" => "junk" } ]))
    refute c.key?("option_styles")
  end

  test "types without option tiles drop the key entirely" do
    %w[open_ended range rating nps tap_card welcome_card].each do |type|
      c = sanitize({ "type" => type, "text" => "Q", "option_styles" => [ { "color" => "#112233" } ] })
      refute c.key?("option_styles"), "#{type} has no per-option tile to style"
    end
  end

  test "non-hash entries are nulled, not crashed on" do
    c = sanitize(mc([ "reddish", 42, { "color" => "#112233" } ]))
    assert_nil c["option_styles"][0]
    assert_nil c["option_styles"][1]
    assert_equal "#112233", c["option_styles"][2]["color"]
  end
end
