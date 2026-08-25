require "test_helper"

# Survey#switch_primary_locale! / Survey.swap_card_primary — re-pointing a
# Verto at a different primary language. The canonical text is the answer key
# (stored answers, quiz `correct` and the token map all speak it), so the swap
# remaps label-keyed structures positionally and is fenced to decks nobody has
# answered.
class SurveyLocaleSwapTest < ActiveSupport::TestCase
  def org
    @org ||= Organisation.create!(name: "O", slug: "swap-#{SecureRandom.hex(3)}")
  end

  def build_survey(cards:, published: false, locales: %w[en fr])
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: locales, cards: cards,
      publish_token: published ? SecureRandom.urlsafe_base64(18) : nil,
      published_at:  published ? Time.current : nil
    )
  end

  CHOICE = {
    "type" => "multiple_choice", "text" => "Favourite?", "description" => "Pick one",
    "options" => [ "Red", "Blue" ],
    "correct" => "Blue",
    "tokens"  => { "Blue" => { "coin" => 5 } },
    "i18n"    => { "fr" => { "text" => "Préféré ?", "description" => "Choisis", "options" => [ "Rouge", "Bleu" ] } }
  }.freeze

  test "swap_card_primary swaps canonical and translated text and remaps label-keyed structures" do
    out = Survey.swap_card_primary(CHOICE.dup, "en", "fr")

    assert_equal "Préféré ?", out["text"]
    assert_equal [ "Rouge", "Bleu" ], out["options"]
    assert_equal "Bleu", out["correct"], "quiz correct should follow its option's new label"
    assert_equal({ "Bleu" => { "coin" => 5 } }, out["tokens"])
    # The old primary is preserved as an ordinary translation…
    assert_equal "Favourite?", out.dig("i18n", "en", "text")
    assert_equal [ "Red", "Blue" ], out.dig("i18n", "en", "options")
    # …and the promoted language's entry is gone (it IS the canonical now).
    assert_nil out.dig("i18n", "fr")
  end

  test "swap_card_primary refuses a positional shear: mismatched option counts keep canonical options" do
    card = CHOICE.merge("i18n" => { "fr" => { "text" => "Préféré ?", "options" => [ "Rouge" ] } })
    out = Survey.swap_card_primary(card, "en", "fr")

    assert_equal "Préféré ?", out["text"], "text still swaps"
    assert_equal [ "Red", "Blue" ], out["options"], "a short translation must not shear labels"
    assert_equal "Blue", out["correct"], "correct stays with the untouched options"
  end

  test "swap_card_primary carries scenario pages by id and tap responses by position" do
    card = {
      "type" => "tap_card", "text" => "Swipe",
      "options" => [ "S1" ],
      "correct" => { "S1" => "yes" },
      "responses" => [ { "key" => "no", "label" => "No" }, { "key" => "yes", "label" => "Yes" } ],
      "pages" => [ { "id" => "p1", "text" => "Once upon" } ],
      "i18n" => { "fr" => { "text" => "Glisse", "options" => [ "É1" ],
                            "responses" => [ "Non", "Oui" ],
                            "pages" => [ { "id" => "p1", "text" => "Il était" } ] } }
    }
    out = Survey.swap_card_primary(card, "en", "fr")

    assert_equal "Il était", out["pages"].first["text"]
    assert_equal %w[Non Oui], out["responses"].map { |r| r["label"] }
    assert_equal({ "É1" => "yes" }, out["correct"], "tap correct keys are the statements; response keys are stable")
    assert_equal [ "No", "Yes" ], out.dig("i18n", "en", "responses")
  end

  test "switch_primary_locale! updates the survey and puts the new primary first" do
    s = build_survey(cards: [ CHOICE.dup ])
    assert s.switch_primary_locale!("fr")
    s.reload
    assert_equal "fr", s.default_locale
    assert_equal %w[fr en], s.verto_locales
    assert_equal "Préféré ?", s.cards.first["text"]
  end

  test "switch_primary_locale! is fenced: locked decks, answered decks, unknown languages" do
    live = build_survey(cards: [ CHOICE.dup ], published: true)
    assert_raises(ArgumentError) { live.switch_primary_locale!("fr") }

    answered = build_survey(cards: [ CHOICE.dup ])
    answered.responses.create!(session_token: SecureRandom.hex(8), status: "completed")
    assert_raises(ArgumentError) { answered.switch_primary_locale!("fr") }

    draft = build_survey(cards: [ CHOICE.dup ])
    assert_raises(ArgumentError) { draft.switch_primary_locale!("de") }

    assert_equal false, draft.switch_primary_locale!(draft.default_locale), "same language is a no-op"
  end
end
