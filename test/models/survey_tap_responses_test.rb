require "test_helper"

# The `responses` card key — a tap card's 2-6 answer scale — as it survives a
# creator's PATCH. Modelled on survey_option_styles_test: the editor sends this
# straight off the DOM, so everything in it is client-supplied and every field
# is allowlisted or dropped.
#
# The one that isn't merely presentational is `key`. It is the value an answer is
# STORED as, and what `tokens` and `correct` are matched against, so a duplicate
# or a crafted one doesn't just look wrong — it silently re-points data.
class SurveyTapResponsesTest < ActiveSupport::TestCase
  # The sanitiser is a class method the controller runs over an editor PATCH, not
  # a model callback (same as option_styles), so it is exercised directly.
  def sanitize(card)
    Survey.sanitize_cards_images!([ card ]).first
  end

  def card_for(responses, type: "tap_card", **extra)
    sanitize({ "type" => type, "cid" => "c1", "text" => "Q", "options" => %w[One Two],
               "responses" => responses }.merge(extra.transform_keys(&:to_s)))
  end

  test "a whole valid scale survives, colours normalised" do
    card = card_for([ { "key" => "no", "label" => "No", "glyph" => "no", "color" => "#D80027" },
                      { "key" => "yes", "label" => "Yes", "glyph" => "yes", "color" => "#01EACB" } ])

    assert_equal %w[no yes], card["responses"].map { |r| r["key"] }
    assert_equal [ "#d80027", "#01eacb" ], card["responses"].map { |r| r["color"] },
                 "one casing in the column, so two decks styled the same colour compare equal"
  end

  test "junk in the presentational fields is dropped, not stored" do
    card = card_for([ { "key" => "no", "label" => "No" },
                      { "key" => "yes", "label" => "Yes",
                        "color" => "javascript:alert(1)", "icon" => "../../etc/passwd",
                        "glyph" => "<script>", "strong" => "sure" } ])
    yes = card["responses"].last

    assert_nil yes["color"], "the colour reaches an inline style — only a real hex may pass"
    assert_nil yes["icon"],  "only an OptionIconLibrary id may pass"
    assert_nil yes["glyph"], "only a TapScales::GLYPHS name may pass"
    assert_equal true, yes["strong"]
  end

  test "a blank, malformed or duplicate key is minted rather than trusted" do
    card = card_for([ { "key" => "", "label" => "A" },
                      { "key" => "yes", "label" => "B" },
                      { "key" => "yes", "label" => "C" },
                      { "key" => "NOT A KEY!", "label" => "D" } ])
    keys = card["responses"].map { |r| r["key"] }

    assert_equal 4, keys.uniq.size, "two responses sharing a key make a token award resolve to whichever is last"
    assert_equal "yes", keys[1], "the first holder of a key keeps it"
    assert(keys.values_at(0, 2, 3).all? { |k| k.match?(/\Ar_[0-9a-f]{8}\z/) })
  end

  test "the scale is bounded at both ends" do
    seven = card_for(TapScales.preset(6) + [ { "key" => "extra", "label" => "Extra" } ])
    assert_equal TapScales::MAX_RESPONSES, seven["responses"].size

    # Below the floor the key goes entirely, so TapScales falls back to the
    # historic three — a working card, where a one-button scale is not.
    one = card_for([ { "key" => "yes", "label" => "Yes" } ])
    refute one.key?("responses")
    assert_equal %w[no unsure yes], TapScales.keys_for(one)
  end

  test "labels and emoji are capped like every other creator-supplied string" do
    card = card_for([ { "key" => "no", "label" => "x" * 200, "emoji" => "👍" * 20 },
                      { "key" => "yes", "label" => "Yes" } ])

    assert_equal TapScales::MAX_LABEL, card["responses"].first["label"].length
    assert_equal Survey::MAX_TOKEN_ICON, card["responses"].first["emoji"].length
  end

  test "a scale carries through a type switch instead of being lost" do
    # Same rule option_images follows: a creator who builds a six-point scale,
    # tries Range to compare and switches back should find their scale.
    card = card_for(TapScales.preset(5), type: "range")

    assert_equal 5, card["responses"].size,
                 "dropping it here means the round trip through another type silently loses the creator's work"
  end

  test "translated labels are realigned to the scale's size" do
    long = card_for(TapScales.preset(4),
                    "i18n" => { "fr" => { "responses" => %w[un deux trois quatre cinq six] } })
    assert_equal %w[un deux trois quatre], long["i18n"]["fr"]["responses"]

    short = card_for(TapScales.preset(5), "i18n" => { "fr" => { "responses" => %w[un deux] } })
    assert_equal [ "un", "deux", "", "", "" ], short["i18n"]["fr"]["responses"],
                 "a short translation pads rather than shifting label 3 onto response 3"
  end

  test "translations for a scale that no longer exists are dropped" do
    card = sanitize({ "type" => "tap_card", "cid" => "c1", "text" => "Q", "options" => %w[One],
                      "i18n" => { "fr" => { "text" => "Q?", "responses" => %w[un deux] } } })

    refute card["i18n"]["fr"].key?("responses"), "a card on the built-in scale has no labels to translate"
    assert_equal "Q?", card["i18n"]["fr"]["text"], "the rest of the translation is untouched"
  end

  test "a scale round-trips through the sanitiser unchanged" do
    once  = card_for(TapScales.preset(6))
    twice = sanitize(once)

    assert_equal once["responses"], twice["responses"],
                 "a sanitiser that keeps changing its mind rewrites the deck on every autosave"
  end
end
