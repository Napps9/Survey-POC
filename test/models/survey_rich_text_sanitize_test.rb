require "test_helper"

# The rich-text layer inside Survey.sanitize_cards_images!: html twins are
# kept only when they sanitise clean AND still read as their plain field, and
# a deck that never used formatting round-trips byte-identically.
class SurveyRichTextSanitizeTest < ActiveSupport::TestCase
  def sanitize(card)
    Survey.sanitize_cards_images!([ card ]).first
  end

  test "equivalent html is kept, diverged html is dropped" do
    c = sanitize({ "type" => "multiple_choice", "text" => "Big question",
                   "text_html" => %(<span class="font-anton">Big</span> question),
                   "description" => "Sub", "description_html" => "<b>Wrong words</b>",
                   "options" => %w[a] })

    assert_equal %(<span class="font-anton">Big</span> question), c["text_html"]
    refute c.key?("description_html"), "html that no longer reads as its plain twin must go"
  end

  test "options_html aligns to options and drops when nothing survives" do
    c = sanitize({ "type" => "multiple_choice", "text" => "Q",
                   "options" => %w[Alpha Beta],
                   "options_html" => [ "<b>Alpha</b>", "<b>Wrong</b>", "<b>Extra</b>" ] })

    assert_equal [ "<b>Alpha</b>", nil ], c["options_html"]

    c = sanitize({ "type" => "multiple_choice", "text" => "Q", "options" => %w[Alpha],
                   "options_html" => [ "<b>Mismatch</b>" ] })
    refute c.key?("options_html")
  end

  test "scenario pages carry an html layer under the same contract" do
    c = sanitize({ "type" => "scenario", "text" => "Q", "options" => %w[a b],
                   "pages" => [ { "id" => "p1", "text" => "Once upon a time",
                                  "html" => "Once <i>upon</i> a time" },
                                { "id" => "p2", "text" => "The end", "html" => "<i>Not the end</i>" } ] })

    assert_equal "Once <i>upon</i> a time", c["pages"][0]["html"]
    refute c["pages"][1].key?("html")
  end

  test "hostile markup is neutralised before storage" do
    c = sanitize({ "type" => "multiple_choice", "text" => "Q",
                   "text_html" => %(<img src=x onerror=alert(1)><b>Q</b><script>x</script>), "options" => %w[a] })

    # The img/script are stripped; the surviving layer must read as "Q" with
    # only allowlisted markup.
    assert c.key?("text_html"), "the legitimate <b>Q</b> layer should survive"
    assert_equal "<b>Q</b>", c["text_html"]
    refute_match(/img|script|onerror/, c["text_html"])
  end

  test "translations stay plain — any *_html inside i18n is stripped" do
    c = sanitize({ "type" => "multiple_choice", "text" => "Q", "options" => %w[a],
                   "i18n" => { "fr" => { "text" => "Qf", "text_html" => "<b>Qf</b>" } } })

    assert_equal "Qf", c["i18n"]["fr"]["text"]
    refute c["i18n"]["fr"].key?("text_html")
  end

  # The regression the whole design guards against: a legacy deck (no rich
  # text anywhere) must come out of the sanitiser exactly as it went in — no
  # new keys, no reordered content.
  test "an unformatted legacy deck round-trips byte-identically" do
    cards = [
      { "type" => "welcome_card", "cid" => "w1", "text" => "Hello" },
      { "type" => "multiple_choice", "cid" => "c1", "text" => "Pick", "options" => %w[a b c],
        "i18n" => { "fr" => { "text" => "Choisir", "options" => %w[x y z] } } },
      { "type" => "scenario", "cid" => "s1", "text" => "Story", "options" => %w[l r],
        "pages" => [ { "id" => "p1", "text" => "Page one" } ] }
    ]
    before = Marshal.load(Marshal.dump(cards))

    after = Survey.sanitize_cards_images!(cards)

    assert_equal before.to_json, after.to_json,
                 "the rich-text layer must be invisible to decks that never used it"
  end
end
