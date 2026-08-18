require "test_helper"

# The tap card's response scale — the 2-6 answers a respondent chooses between
# on each swipe statement.
#
# The load-bearing property is that a card WITHOUT a stored scale behaves
# exactly as it did before scales were configurable: every deck in production,
# every partner import (app/lib/verto_decks) and every AI-generated card is in
# that state, and their answers are already sitting in the responses table keyed
# by "yes" / "unsure" / "no".
class TapScalesTest < ActiveSupport::TestCase
  test "a card with no stored scale is on the historic three, in the historic order" do
    keys = TapScales.keys_for({ "type" => "tap_card" })

    assert_equal %w[no unsure yes], keys,
                 "answers already collected are stored against these keys — changing them re-points every one"
  end

  test "the historic three keep their labels, directions and glyphs" do
    resolved = TapScales.for_card({ "type" => "tap_card" })

    assert_equal %w[No Unsure Yes], resolved.map { |r| r["label"] }
    assert_equal %w[left up right], resolved.map { |r| r["direction"] }
    assert_equal %w[no unsure yes], resolved.map { |r| r["glyph"] }
    refute resolved.any? { |r| r["fan"] }, "three responses are a row of circles, not a fan"
  end

  test "every preset is ordered most-negative first" do
    TapScales.preset_counts.each do |n|
      preset = TapScales.preset(n)
      assert_equal n, preset.size, "preset #{n} should have #{n} entries"
      assert_equal "left",  TapScales.direction_for(0, n),     "preset #{n} should open on the negative end"
      assert_equal "right", TapScales.direction_for(n - 1, n), "preset #{n} should close on the positive end"
    end
  end

  test "the middle of an odd scale flies up, and an even scale has no middle" do
    assert_equal %w[left up right],              (0..2).map { |i| TapScales.direction_for(i, 3) }
    assert_equal %w[left left right right],      (0..3).map { |i| TapScales.direction_for(i, 4) }
    assert_equal %w[left left up right right],   (0..4).map { |i| TapScales.direction_for(i, 5) }

    assert_equal 2, TapScales.index_for_direction("up", 5)
    assert_nil TapScales.index_for_direction("up", 4),
               "an even scale has no middle answer, so a fling upward must commit nothing"
  end

  test "a fling commits the extreme on its side, whatever the scale" do
    [ 2, 3, 4, 5, 6 ].each do |n|
      assert_equal 0,     TapScales.index_for_direction("left", n),  "left should be the most negative on a #{n}-point scale"
      assert_equal n - 1, TapScales.index_for_direction("right", n), "right should be the most positive on a #{n}-point scale"
    end
  end

  test "five and up fan out, four and under stay a row" do
    refute TapScales.fan?(4)
    assert TapScales.fan?(5)
    assert TapScales.for_card({ "type" => "tap_card", "responses" => TapScales.preset(5) }).all? { |r| r["fan"] }
  end

  # The arc is the same shape as the gesture, so these are not free numbers: the
  # first response has to sit left of centre, the last right of it, and an odd
  # scale's middle has to sit at the apex above both — otherwise a respondent is
  # told to fling one way by the layout and another by the animation.
  # The arc is the same shape as the gesture, so these are not free numbers.
  # Where a response SITS has to agree with where the card FLIES when you pick
  # it, or the layout tells a respondent one thing and the animation another.
  #
  # Note the arc curls back in at its ends — the most extreme answers sit closer
  # to the centre line than their neighbours, exactly as the design has them. So
  # the invariant is which SIDE a response is on, never how far along x it is.
  test "each fanned response sits on the side its swipe flies to" do
    [ 5, 6 ].each do |n|
      (0...n).each do |i|
        x, _y = TapScales.fan_position(i, n)
        case TapScales.direction_for(i, n)
        when "left"  then assert_operator x, :<, TapScales::FAN_CX, "#{n}/#{i} flies left but sits right of centre"
        when "right" then assert_operator x, :>, TapScales::FAN_CX, "#{n}/#{i} flies right but sits left of centre"
        when "up"    then assert_in_delta TapScales::FAN_CX, x, 2.0, "#{n}/#{i} flies up, so it belongs at the apex"
        end
      end
    end
  end

  test "the apex is the top of the arc and the extremes are level" do
    ys = (0...5).map { |i| TapScales.fan_position(i, 5).last }

    assert_equal ys.min, ys[2], "the middle of an odd scale is the apex — the answer a fling upward means"
    assert_in_delta ys.first, ys.last, 1.0, "the two extremes sit level with each other"
    assert_equal [ ys.first, ys.last ].max, ys.max, "the scale opens at the bottom of the card"
  end

  test "every fanned response lands inside the card" do
    [ 5, 6 ].each do |n|
      (0...n).each do |i|
        x, y = TapScales.fan_position(i, n)
        assert_operator x, :>, 10, "#{n}/#{i} would hang off the left edge"
        assert_operator x, :<, 90, "#{n}/#{i} would hang off the right edge"
        assert_operator y, :>, 20, "#{n}/#{i} would sit under the statement band"
        assert_operator y, :<, 85, "#{n}/#{i} would sit under the remaining-cards dots"
      end
    end
  end

  test "presets carry exactly the mark their shape renders" do
    # icon → emoji → glyph is one precedence everywhere, so a preset that
    # carried both would render its emoji inside a circle meant for a glyph.
    [ 2, 3, 4 ].each do |n|
      TapScales.preset(n).each do |r|
        assert r["glyph"].present?, "#{n}-point #{r['key']} draws a circle, so it needs a glyph"
        assert_nil r["emoji"], "#{n}-point #{r['key']} draws a circle — an emoji here would outrank the glyph"
      end
    end
    [ 5, 6 ].each do |n|
      TapScales.preset(n).each do |r|
        assert r["emoji"].present?, "#{n}-point #{r['key']} draws a pill, so it needs an emoji"
      end
    end
  end

  test "a creator's label wins over the preset, and the key does not move with it" do
    card = { "type" => "tap_card",
             "responses" => [ { "key" => "no", "label" => "Never" }, { "key" => "yes", "label" => "Always" } ] }

    assert_equal %w[Never Always], TapScales.for_card(card).map { |r| r["label"] }
    assert_equal %w[no yes], TapScales.keys_for(card),
                 "a relabelled response must keep its key, or every answer stored against it is orphaned"
  end

  test "a bare key still resolves the colour and glyph its preset defines" do
    card = { "type" => "tap_card", "responses" => [ { "key" => "no" }, { "key" => "yes" } ] }
    resolved = TapScales.for_card(card)

    assert_equal "No", resolved.first["label"]
    assert_equal "no", resolved.first["glyph"]
    assert resolved.first["color"].present?
  end

  test "translated labels come from the card's i18n, aligned positionally" do
    card = { "type" => "tap_card", "responses" => TapScales.preset(2),
             "i18n" => { "fr" => { "responses" => [ "Non", "Oui" ] } } }

    assert_equal %w[Non Oui], TapScales.for_card(card, locale: "fr").map { |r| r["label"] }
    assert_equal %w[No Yes],  TapScales.for_card(card, locale: "fr").map { |r| r["canonical"] },
                 "the canonical label stays primary — it is what the editor round-trips"
  end

  test "a translation that comes up short falls back per slot" do
    card = { "type" => "tap_card", "responses" => TapScales.preset(3),
             "i18n" => { "fr" => { "responses" => [ "Non" ] } } }

    assert_equal [ "Non", "Unsure", "Yes" ], TapScales.for_card(card, locale: "fr").map { |r| r["label"] }
  end

  test "preset labels follow the Verto's language, not the viewer's" do
    assert_equal "Neutre", TapScales.preset_label("neutral", "Neutral", "fr")
    assert_equal "Non",    TapScales.preset_label("no", "No", "fr"),
                 "the historic three resolve through card.swipe_*, which every locale already carries"
  end

  test "a card on the built-in scale speaks the card's language" do
    # The preset carries an ENGLISH fallback label. Reading it straight through
    # meant a French Verto's untouched tap card answered "No / Unsure / Yes" —
    # a preset label is not content until a creator keeps it, so it has to
    # resolve through the locale like every other placeholder.
    card = { "type" => "tap_card" }

    assert_equal %w[Non Incertain Oui], TapScales.for_card(card, locale: "fr").map { |r| r["label"] }
    assert_equal %w[No Unsure Yes],     TapScales.for_card(card).map { |r| r["label"] }
  end

  test "a stored label is content and stays put until it is translated" do
    # The mirror of the case above: once a creator has kept (or written) a
    # label it is their words, and the locale must not overwrite them.
    card = { "type" => "tap_card", "responses" => TapScales.preset(2) }

    assert_equal %w[No Yes], TapScales.for_card(card, locale: "fr").map { |r| r["label"] },
                 "a kept label is card content — only card i18n may translate it"
  end

  test "a malformed or out-of-bounds scale falls back to the historic three" do
    [ "not an array",
      [ { "key" => "only_one" } ],
      (1..7).map { |i| { "key" => "r#{i}" } },
      [ { "key" => "ok" }, { "key" => "BAD KEY" } ],
      [ { "key" => "ok" }, "not a hash" ] ].each do |bad|
      assert_equal %w[no unsure yes], TapScales.keys_for({ "type" => "tap_card", "responses" => bad }),
                   "#{bad.inspect} should fall back to a working card, not render a broken one"
    end
  end

  test "the glyph list matches the icons the helper can actually draw" do
    assert_equal ApplicationHelper::TAP_RESPONSE_ICONS.keys.sort, TapScales::GLYPHS.sort,
                 "a preset naming a glyph the helper has no path for renders the fallback instead"
  end

  test "every preset entry is well formed" do
    TapScales.preset_counts.each do |n|
      TapScales.preset(n).each do |r|
        assert r["key"].to_s.match?(TapScales::KEY_FORMAT), "#{n}/#{r['key']}: key must survive the sanitiser"
        assert r["label"].present?, "#{n}/#{r['key']}: needs an English fallback label"
        assert BrandPalette.valid_hex?(r["color"].to_s), "#{n}/#{r['key']}: colour must survive the sanitiser"
      end
      assert_equal TapScales.preset(n).map { |r| r["key"] }.uniq.size, n, "preset #{n} has a duplicate key"
    end
  end

  test "the editor blob carries the presets in the Verto's language" do
    blob = JSON.parse(TapScales.to_json("fr"))

    assert_equal TapScales::MAX_RESPONSES, blob["max"]
    assert_equal "Neutre", blob.dig("presets", "5", 2, "label")
  end

  # The eye reads the ROWS of the fan, not the angles between the pins. An even
  # angle step bunches at the apex — a five-point scale's rows sat 14.84% then
  # 24.50% of the card apart, so the two "strongly" pins hung below the rest and
  # the scale read as bottom-heavy (and, with the extremes also drawn in a
  # heavier stroke at the time, as leading). fan_position spaces by row instead.
  test "the fan's rows are evenly spaced, at every scale size" do
    (TapScales::FAN_THRESHOLD..6).each do |count|
      rows = (0...count).map { |i| TapScales.fan_position(i, count)[1] }.uniq.sort
      gaps = rows.each_cons(2).map { |a, b| (b - a).round(2) }

      assert gaps.any?, "#{count}-point fan collapsed to a single row"
      assert_in_delta gaps.min, gaps.max, 0.05,
                      "#{count}-point fan rows are unevenly spaced: #{rows.inspect} (gaps #{gaps.inspect})"
    end
  end

  # Evening the rows must not move the ends of the scale or the apex — those are
  # what the arc reads as, and what the pill-width ceiling is measured against.
  test "evening the rows leaves the arc's extremes and apex where they were" do
    five = (0...5).map { |i| TapScales.fan_position(i, 5) }

    assert_equal [ 31.53, 74.84 ], five.first, "the bottom-left end of the scale moved"
    assert_equal [ 68.47, 74.84 ], five.last,  "the bottom-right end of the scale moved"
    assert_equal [ 50.0,  35.5  ], five[2],    "the apex is no longer centred at the top"
  end

  # The pill width is bounded by the closest SAME-HEIGHT pair (see the
  # --tap-pill-w note in application.css). Spacing by row moved the near-apex
  # pins outward, so that bound must not have tightened.
  test "no same-height pair is closer than the pill width allows" do
    (TapScales::FAN_THRESHOLD..6).each do |count|
      by_row = (0...count).map { |i| TapScales.fan_position(i, count) }
                          .group_by(&:last)
                          .transform_values { |pts| pts.map(&:first) }

      by_row.each do |y, xs|
        next if xs.size < 2
        assert (xs.max - xs.min) >= 34.0,
               "#{count}-point fan: row at #{y}% has pins only #{(xs.max - xs.min).round(2)}% apart, " \
               "which is inside --tap-pill-w"
      end
    end
  end
end
