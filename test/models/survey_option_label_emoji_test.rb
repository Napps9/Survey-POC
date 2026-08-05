require "test_helper"

# Promoting an option label's emoji into that option's icon tile. The risk here
# is not the emoji — it's that an option label is an ANSWER KEY (`correct`,
# `tokens`, logic `match.value` all reference it as a string), so a rewrite has
# to carry every one of those with it, and must never touch a Verto whose
# answers have already been collected.
class SurveyOptionLabelEmojiTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "Emoji", slug: "em-#{SecureRandom.hex(3)}")
  end

  def build(cards, **attrs)
    @org.surveys.create!(title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards, **attrs)
  end

  test "a leading emoji moves out of the label and into the option's icon" do
    s = build([ { "type" => "multiple_choice", "text" => "Q",
                  "options" => [ "🎯 Pay off debt", "Start saving", "🔥 Build investments" ] } ])
    card = s.reload.cards.first

    assert_equal [ "Pay off debt", "Start saving", "Build investments" ], card["options"]
    assert_equal "🎯", card["option_styles"][0]["emoji"]
    assert_nil   card["option_styles"][1]
    assert_equal "🔥", card["option_styles"][2]["emoji"]
  end

  test "it applies to every icon-select type and leaves the others alone" do
    Survey::OPTION_STYLE_TYPES.each do |type|
      s = build([ { "type" => type, "text" => "Q", "options" => [ "🎯 Alpha", "🔥 Beta" ] } ])
      card = s.reload.cards.first
      assert_equal "Alpha", card["options"][0], "#{type} should hoist"
      assert_equal "🎯", card["option_styles"][0]["emoji"], "#{type} should carry the emoji"
    end

    # tap_card isn't styleable — option_styles would be stripped by the
    # sanitiser, so there is no tile to move an emoji into.
    s = build([ { "type" => "tap_card", "text" => "Q", "options" => [ "🎯 Alpha", "🔥 Beta" ] } ])
    assert_equal [ "🎯 Alpha", "🔥 Beta" ], s.reload.cards.first["options"]
  end

  test "the quiz answer, token keys and logic routes follow the rename" do
    s = build([ { "type" => "multiple_choice", "cid" => "c1", "text" => "Q",
                  "options" => [ "🎯 Pay off debt", "Start saving" ],
                  "correct" => "🎯 Pay off debt",
                  "tokens"  => { "🎯 Pay off debt" => { "t1" => 5 }, "Start saving" => { "t1" => 2 } },
                  "logic"   => { "routes" => [
                    { "match" => { "op" => "equals", "value" => "🎯 Pay off debt" },
                      "to" => { "card" => "c2" } }
                  ] } },
                { "type" => "multiple_choice", "cid" => "c2", "text" => "Q2", "options" => %w[a b] } ])
    card = s.reload.cards.first

    assert_equal "Pay off debt", card["correct"], "a stale correct value would unset the answer"
    assert_equal({ "t1" => 5 }, card["tokens"]["Pay off debt"], "token award must follow the label")
    assert_equal({ "t1" => 2 }, card["tokens"]["Start saving"], "untouched options keep their award")
    assert_equal "Pay off debt", card["logic"]["routes"][0]["match"]["value"],
                 "a stale route value would silently stop the branch firing"
  end

  test "a multi-select card's array of correct answers follows too" do
    s = build([ { "type" => "select_many", "text" => "Q",
                  "options" => [ "🎯 Alpha", "🔥 Beta", "Gamma" ],
                  "correct" => [ "🎯 Alpha", "Gamma" ] } ])
    assert_equal [ "Alpha", "Gamma" ], s.reload.cards.first["correct"]
  end

  test "an option that already has a chosen icon or emoji is left completely alone" do
    s = build([ { "type" => "multiple_choice", "text" => "Q",
                  "options" => [ "🎯 Pay off debt", "🔥 Start saving" ],
                  "option_styles" => [ { "emoji" => "⭐" }, { "icon" => "basketball" } ] } ])
    card = s.reload.cards.first

    assert_equal [ "🎯 Pay off debt", "🔥 Start saving" ], card["options"],
                 "the picked style wins the tile, so there is nowhere to put the label emoji"
    assert_equal "⭐", card["option_styles"][0]["emoji"]
    assert_equal "basketball", card["option_styles"][1]["icon"]
  end

  test "a published Verto is never rewritten" do
    s = build([ { "type" => "multiple_choice", "text" => "Q", "options" => [ "🎯 Pay off debt" ] } ],
              publish_token: SecureRandom.hex(8), published_at: Time.current)

    assert_equal [ "🎯 Pay off debt" ], s.reload.cards.first["options"],
                 "a live deck's labels are the answer key for responses already collected"
  end

  test "an emoji-only label keeps its emoji" do
    s = build([ { "type" => "multiple_choice", "text" => "Q", "options" => [ "🎯", "Real option" ] } ])
    card = s.reload.cards.first

    assert_equal [ "🎯", "Real option" ], card["options"],
                 "blanking the label would drop the option on the next autosave"
  end

  test "the rewrite settles after one pass" do
    s = build([ { "type" => "multiple_choice", "text" => "Q",
                  "options" => [ "🎯 Pay off debt", "🔥 Start saving 🎉" ] } ])
    once = s.reload.cards

    s.update!(cards: once)
    assert_equal once, s.reload.cards, "saving again must not nibble another emoji off"
  end

  test "the rich-text twin keeps its formatting through the rename" do
    s = build([ { "type" => "multiple_choice", "text" => "Q",
                  "options" => [ "🎯 Pay off debt" ],
                  "options_html" => [ "🎯 <b>Pay off debt</b>" ] } ])
    card = s.reload.cards.first

    assert_equal "Pay off debt", card["options"][0]
    assert_includes card["options_html"][0].to_s, "<b>",
                    "the formatting layer must survive the label rewrite"
    refute_includes card["options_html"][0].to_s, "🎯"
  end
end
