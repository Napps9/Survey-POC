require "test_helper"

# LanguageCheckLines turns a deck into the per-(card, language) rows the
# Language check screen reviews. Its two load-bearing behaviours are the
# fallback (a line with no translation shows the primary wording, because that
# is what the player shows) and the digest (what an approval is an approval of).
class LanguageCheckLinesTest < ActiveSupport::TestCase
  def card
    {
      "cid" => "c1", "type" => "multiple_choice", "text" => "Favourite colour?",
      "description" => "Pick one", "options" => %w[Blue Green],
      "i18n" => { "es" => { "text" => "¿Color favorito?", "options" => %w[Azul Verde] } }
    }
  end

  def canonical
    LanguageCheckLines.canonical_content(card)
  end

  test "every field SurveyTranslator writes is a field this screen reviews" do
    # A field translated by the app but absent from FIELDS is a line nobody is
    # ever shown and therefore nobody ever checks. Read off the translator's own
    # tool schema rather than restated, so adding one there fails here.
    translated = SurveyTranslator::TOOL.dig(:input_schema, :properties, :cards, :items, :properties).keys.map(&:to_s)
    missing = translated - LanguageCheckLines::FIELDS
    assert_empty missing,
                 "SurveyTranslator writes #{missing.inspect}, which the Language check screen would never show"
  end

  test "a secondary language falls back field by field to the primary wording" do
    content = LanguageCheckLines.translated_content(card, "es", canonical)
    assert_equal "¿Color favorito?", content["text"]
    assert_equal "Pick one", content["description"],
                 "the player renders the primary sub-text here, so the reviewer must see it"
    assert_includes content["untranslated"], "description"
    assert_not_includes content["untranslated"], "text"
  end

  test "a language with no entry at all is marked untranslated rather than shown as a translation" do
    content = LanguageCheckLines.translated_content(card, "fr", canonical)
    assert_equal "Favourite colour?", content["text"]
    assert LanguageCheckLines.untranslated?(content),
           "passing English off as French is the most misleading thing this page could do"
  end

  test "a partly translated line is not reported as untranslated" do
    content = LanguageCheckLines.translated_content(card, "es", canonical)
    assert_not LanguageCheckLines.untranslated?(content)
  end

  test "a translated option list is never longer or shorter than the canonical one" do
    long  = card.deep_merge("i18n" => { "es" => { "options" => %w[Azul Verde Rojo] } })
    short = card.deep_merge("i18n" => { "es" => { "options" => %w[Azul] } })
    assert_equal 2, LanguageCheckLines.translated_content(long, "es", canonical)["options"].length
    assert_equal [ "Azul", "Green" ],
                 LanguageCheckLines.translated_content(short, "es", canonical)["options"],
                 "an untranslated slot reads in the primary language, exactly as the player renders it"
  end

  test "scenario pages align by id, never by position" do
    paged = {
      "cid" => "c2", "type" => "scenario", "text" => "A story",
      "pages" => [ { "id" => "p1", "text" => "First" }, { "id" => "p2", "text" => "Second" } ],
      "i18n" => { "es" => { "pages" => [ { "id" => "p2", "text" => "Segundo" } ] } }
    }
    content = LanguageCheckLines.translated_content(paged, "es", LanguageCheckLines.canonical_content(paged))
    assert_equal "First", content["pages"][0]["text"], "p1 has no translation and falls back"
    assert_equal "Segundo", content["pages"][1]["text"], "p2 matched by id, not by being second"
  end

  test "the digest changes when the words change and not when they do not" do
    a = LanguageCheckLines.translated_content(card, "es", canonical)
    b = LanguageCheckLines.translated_content(card.deep_dup, "es", canonical)
    assert_equal LanguageCheckLines.digest(a), LanguageCheckLines.digest(b)

    edited = card.deep_merge("i18n" => { "es" => { "text" => "¿Cuál es tu color?" } })
    assert_not_equal LanguageCheckLines.digest(a),
                     LanguageCheckLines.digest(LanguageCheckLines.translated_content(edited, "es", canonical))
  end

  test "filling in an unrelated field does not lapse an approval of the words" do
    # `untranslated` is an annotation about where the words came from, not the
    # words. Hashing it would lapse every approval on a line the moment any
    # other field was translated.
    a = LanguageCheckLines.translated_content(card, "es", canonical)
    b = a.merge("untranslated" => [])
    assert_equal LanguageCheckLines.digest(a), LanguageCheckLines.digest(b)
  end

  test "a deck becomes one entry per card with a line per language, in deck order" do
    survey = Survey.new(default_locale: "en", locales: %w[en es fr],
                        cards: [ card, { "cid" => "c2", "type" => "open_ended", "text" => "Why?" } ])
    rows = LanguageCheckLines.for(survey)
    assert_equal %w[c1 c2], rows.map { |r| r[:cid] }
    assert_equal [ 0, 1 ], rows.map { |r| r[:index] }
    assert_equal %w[en es fr], rows.first[:lines].map { |l| l[:locale] }
    assert rows.first[:lines].first[:primary], "the primary language comes first"
  end

  test "a card with no words of its own is not a line to review" do
    survey = Survey.new(default_locale: "en", locales: %w[en es],
                        cards: [ { "cid" => "c_img", "type" => "welcome_card" }, card ])
    assert_equal [ "c1" ], LanguageCheckLines.for(survey).map { |r| r[:cid] }
  end

  test "only the fields a card actually has are offered for review" do
    bare = { "cid" => "c3", "type" => "open_ended", "text" => "Why?" }
    assert_equal [ "text" ], LanguageCheckLines.present_fields(LanguageCheckLines.canonical_content(bare))
  end

  test "tap scale labels are reviewable alongside options" do
    tap = {
      "cid" => "c4", "type" => "tap_card", "text" => "How often?",
      "options" => [ "Sleep", "Exercise" ],
      "responses" => [ { "key" => "never", "label" => "Never" }, { "key" => "often", "label" => "Often" } ]
    }
    content = LanguageCheckLines.canonical_content(tap)
    assert_equal [ "Never", "Often" ], content["responses"]
    assert_includes LanguageCheckLines.present_fields(content), "responses"
  end
end
