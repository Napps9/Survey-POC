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

  # rating_icon themes the rating answer-type icon to the Verto.
  Struct.new("ThemedSurvey", :theme, :title, :key_insight) unless defined?(Struct::ThemedSurvey)
  def themed(theme: nil, title: nil, key_insight: nil)
    Struct::ThemedSurvey.new(theme, title, key_insight)
  end

  test "themed Vertos rate in a matching emoji" do
    assert_equal({ on: "🚀", off: "🚀", kind: "emoji" }, rating_icon(themed(theme: "space")))
    assert_equal "🍔", rating_icon(themed(theme: "Food and nutrition"))[:on]
    assert_equal "⚽", rating_icon(themed(theme: "Football fans"))[:on]
  end

  # nps_container_shape themes the NPS liquid-container silhouette per Verto.
  test "nps container shape is a known shape, stable per theme, and varies by theme" do
    %w[Space Food Climate].each do |t|
      assert_includes ApplicationHelper::NPS_CONTAINER_SHAPES, nps_container_shape(themed(theme: t))
    end
    assert_equal nps_container_shape(themed(theme: "Mountains")), nps_container_shape(themed(theme: "Mountains"))
    shapes = %w[Space Food Climate Music Travel Sport Fashion Coffee Gaming Health]
             .map { |t| nps_container_shape(themed(theme: t)) }.uniq
    assert_operator shapes.size, :>, 1, "expected NPS container shapes to vary across themes"
  end

  test "nps container shape falls back for a blank or nil theme" do
    assert_equal ApplicationHelper::NPS_CONTAINER_SHAPES.first, nps_container_shape(themed(theme: ""))
    assert_equal ApplicationHelper::NPS_CONTAINER_SHAPES.first, nps_container_shape(nil)
  end

  test "singularised matching means plurals and variants hit without being listed" do
    # "rockets"/"fans"/"dogs" aren't in the keyword lists; singularising both
    # sides makes them match anyway.
    assert_equal "🚀", rating_icon(themed(theme: "All about rockets"))[:on]
    assert_equal "⚽", rating_icon(themed(theme: "Football fans"))[:on]
    assert_equal "🐾", rating_icon(themed(theme: "Dogs and cats"))[:on]
  end

  test "draws on the title and key_insight, not just the theme" do
    # A terse/unmatched theme still resolves via the descriptive title.
    icon = rating_icon(themed(theme: "Q2 pulse", title: "How fans feel about the football season"))
    assert_equal "⚽", icon[:on]
  end

  test "the dominant subject wins when several themes appear" do
    # "space" appears twice (theme + insight), "food" once — rocket wins.
    icon = rating_icon(themed(theme: "Space exploration",
                              key_insight: "what food astronauts want in space"))
    assert_equal "🚀", icon[:on]
  end

  test "matches whole words, not substrings" do
    # "start" contains "star" but must not trigger the space rocket; it has no
    # themed match, so it falls back to the classic star.
    assert_equal "star", rating_icon(themed(theme: "Startup founders"))[:kind]
  end

  test "untyped or unmatched Vertos keep the classic star" do
    assert_equal({ on: "★", off: "☆", kind: "star" }, rating_icon(themed(theme: "")))
    assert_equal({ on: "★", off: "☆", kind: "star" }, rating_icon(nil))
    assert_equal "star", rating_icon(themed(theme: "Quarterly NPS pulse"))[:kind]
  end
end
