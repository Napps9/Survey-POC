require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  # editor_cards_i18n powers the inline #survey-cards-i18n island. It must keep
  # the translatable text the language-tab JS reads, and drop the heavy
  # image/structural fields so base64 data URLs aren't serialised inline.

  test "keeps text, description and options per locale" do
    cards = [ {
      "type" => "multiple_choice",
      "text" => "Favourite sport?",
      "description" => "Pick one",
      "options" => %w[Football Rugby],
      "i18n" => { "fr" => { "text" => "Sport préféré ?", "options" => %w[Foot Rugby] } }
    } ]
    out = editor_cards_i18n(cards)
    assert_equal "Favourite sport?", out.first["text"]
    assert_equal "Pick one", out.first["description"]
    assert_equal %w[Football Rugby], out.first["options"]
    assert_equal "Sport préféré ?", out.first.dig("i18n", "fr", "text")
    assert_equal %w[Foot Rugby], out.first.dig("i18n", "fr", "options")
  end

  test "drops image and option_images (base64) and structural fields" do
    big = "data:image/webp;base64,#{"A" * 5000}"
    cards = [ {
      "type" => "tap_card",
      "text" => "Swipe",
      "image" => big,
      "option_images" => [ big, big ],
      "options" => %w[A B],
      "correct" => { "A" => "right" }
    } ]
    out = editor_cards_i18n(cards)
    refute out.first.key?("image")
    refute out.first.key?("option_images")
    refute out.first.key?("type")
    refute out.first.key?("correct")
    refute_includes out.to_json, "AAAA", "base64 image data must not reach the island"
  end
end
