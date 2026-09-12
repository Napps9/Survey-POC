require "test_helper"

# The card intro modal — a creator-written pop-up shown over the card it
# explains. Its whole storage contract is two bounded scalars whose PRESENCE is
# the flag, so the sanitiser is where "does this card have a modal?" is
# actually decided, and these are the answers it has to give.
class SurveyCardModalTest < ActiveSupport::TestCase
  def sanitize(card)
    Survey.sanitize_cards_images!([ card ]).first
  end

  def card(**overrides)
    { "type" => "multiple_choice", "text" => "Q", "options" => %w[a b] }.merge(overrides)
  end

  test "words are trimmed and kept" do
    c = sanitize(card("modal_title" => "  Before you answer  ",
                      "modal_body"  => "  Think about the last year.  "))

    assert_equal "Before you answer", c["modal_title"]
    assert_equal "Think about the last year.", c["modal_body"]
  end

  test "both fields are bounded" do
    c = sanitize(card("modal_title" => "t" * 500, "modal_body" => "b" * 5_000))

    assert_equal Survey::MAX_MODAL_TITLE, c["modal_title"].length
    assert_equal Survey::MAX_MODAL_BODY, c["modal_body"].length
  end

  test "blank words mean no modal — the keys go rather than being stored empty" do
    c = sanitize(card("modal_title" => "   ", "modal_body" => ""))

    refute c.key?("modal_title"), "presence IS the flag; a blank one would make an empty pop-up"
    refute c.key?("modal_body")
  end

  test "a title alone is a modal, and so is a body alone" do
    assert_equal "Heads up", sanitize(card("modal_title" => "Heads up"))["modal_title"]
    assert_equal "Read this", sanitize(card("modal_body" => "Read this"))["modal_body"]
  end

  test "it is not gated on card type — a modal explains whatever it is hung on" do
    %w[welcome_card open_ended range consent_gate respondent_code].each do |type|
      c = sanitize(card("type" => type, "modal_body" => "Why we ask"))
      assert_equal "Why we ask", c["modal_body"], "#{type} should keep its modal"
    end
  end

  test "the body's rich-text layer survives only while it reads as its plain twin" do
    kept = sanitize(card("modal_body" => "Read this carefully",
                         "modal_body_html" => "Read <b>this</b> carefully"))
    assert_equal "Read <b>this</b> carefully", kept["modal_body_html"]

    drifted = sanitize(card("modal_body" => "Read this carefully",
                            "modal_body_html" => "Something else entirely"))
    refute drifted.key?("modal_body_html"), "html that stopped describing the text is dropped"
  end

  test "removing the body takes its html with it" do
    c = sanitize(card("modal_body" => "", "modal_body_html" => "<b>orphan</b>"))

    refute c.key?("modal_body_html")
  end

  test "a translation cannot outlive the modal it translates" do
    c = sanitize(card("modal_title" => "", "modal_body" => "",
                      "i18n" => { "es" => { "text" => "P", "modal_title" => "Ojo",
                                            "modal_body" => "Lee esto" } }))

    entry = c.dig("i18n", "es")
    assert_equal "P", entry["text"], "the rest of the translation is untouched"
    refute entry.key?("modal_title"),
           "a Spanish modal with no primary would render a modal in Spanish only"
    refute entry.key?("modal_body")
  end

  test "a translation's words are bounded like the primary's, and never carry html" do
    c = sanitize(card("modal_title" => "T", "modal_body" => "B",
                      "i18n" => { "es" => { "modal_title" => "t" * 500,
                                            "modal_body" => "b" * 5_000,
                                            "modal_body_html" => "<b>no</b>" } }))

    entry = c.dig("i18n", "es")
    assert_equal Survey::MAX_MODAL_TITLE, entry["modal_title"].length
    assert_equal Survey::MAX_MODAL_BODY, entry["modal_body"].length
    refute entry.key?("modal_body_html"), "translations are plain, exactly like pages"
  end

  test "a card with no modal serialises exactly as it did before the feature" do
    assert_equal card, sanitize(card).except("cid"),
                 "an untouched deck must not grow keys it never asked for"
  end

  test "swapping the primary language promotes the modal with the rest of the words" do
    c = Survey.swap_card_primary(
      { "type" => "open_ended", "text" => "How was it?",
        "modal_title" => "Before you answer", "modal_body" => "In your own words.",
        "modal_body_html" => "In your <b>own</b> words.",
        "i18n" => { "es" => { "text" => "¿Qué tal?", "modal_title" => "Antes de responder",
                              "modal_body" => "Con tus palabras." } } },
      "en", "es"
    )

    assert_equal "Antes de responder", c["modal_title"]
    assert_equal "Con tus palabras.", c["modal_body"]
    refute c.key?("modal_body_html"),
           "the formatting described the English characters, which are no longer there"
    assert_equal "Before you answer", c.dig("i18n", "en", "modal_title"),
                 "the old primary becomes a translation like every other field"
    assert_equal "In your own words.", c.dig("i18n", "en", "modal_body")
  end

  test "a card whose translation has no modal keeps the primary's on a swap" do
    c = Survey.swap_card_primary(
      { "type" => "open_ended", "text" => "How was it?",
        "modal_title" => "Before you answer",
        "i18n" => { "es" => { "text" => "¿Qué tal?" } } },
      "en", "es"
    )

    assert_equal "Before you answer", c["modal_title"],
                 "an untranslated modal is what the player renders, so it must survive"
  end

  test "a translation merges into i18n like every other translated field" do
    cards = Survey.merge_card_translations(
      [ { "type" => "open_ended", "text" => "How was it?", "modal_title" => "Heads up",
          "modal_body" => "In your own words." } ],
      "fr",
      [ { "text" => "C'était comment ?", "modal_title" => "Attention",
          "modal_body" => "Avec tes mots." } ]
    )

    entry = cards.first.dig("i18n", "fr")
    assert_equal "Attention", entry["modal_title"]
    assert_equal "Avec tes mots.", entry["modal_body"]
  end
end
