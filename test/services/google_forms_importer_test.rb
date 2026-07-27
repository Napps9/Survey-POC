require "test_helper"

class GoogleFormsImporterTest < ActiveSupport::TestCase
  # A canned form covering every question shape we map.
  FORM = {
    "info" => { "title" => "Space survey", "description" => "For under 10s" },
    "items" => [
      { "title" => "Pick a planet",
        "questionItem" => { "question" => { "choiceQuestion" => {
          "type" => "RADIO", "options" => [ { "value" => "Mars" }, { "value" => "Venus" } ]
        } } } },
      { "title" => "Which do you like?",
        "questionItem" => { "question" => { "choiceQuestion" => {
          "type" => "CHECKBOX", "options" => [ { "value" => "Stars" }, { "value" => "Moons" } ]
        } } } },
      { "title" => "How likely to recommend?",
        "questionItem" => { "question" => { "scaleQuestion" => { "low" => 0, "high" => 10 } } } },
      { "title" => "Rate the mission",
        "questionItem" => { "question" => { "scaleQuestion" => { "low" => 1, "high" => 5 } } } },
      { "title" => "Star rating",
        "questionItem" => { "question" => { "ratingQuestion" => { "ratingScaleLevel" => 5 } } } },
      { "title" => "Anything else?",
        "questionItem" => { "question" => { "textQuestion" => { "paragraph" => true } } } },
      { "title" => "When were you born?",
        "questionItem" => { "question" => { "dateQuestion" => {} } } },
      { "title" => "Upload a drawing",
        "questionItem" => { "question" => { "fileUploadQuestion" => {} } } },
      { "title" => "A section header", "textItem" => {} },
      { "title" => "Rate these",
        "questionGroupItem" => {
          "grid" => { "columns" => { "type" => "RADIO", "options" => [ { "value" => "Good" }, { "value" => "Bad" } ] } },
          "questions" => [
            { "rowQuestion" => { "title" => "Rockets" } },
            { "rowQuestion" => { "title" => "Aliens" } }
          ]
        } }
    ]
  }.freeze

  def cards
    @cards ||= GoogleFormsImporter.call(FORM)["cards"]
  end

  test "carries the form title and description" do
    out = GoogleFormsImporter.call(FORM)
    assert_equal "Space survey", out["title"]
    assert_equal "For under 10s", out["description"]
  end

  test "radio → multiple_choice with its options, verbatim text" do
    c = cards.find { |x| x["text"] == "Pick a planet" }
    assert_equal "multiple_choice", c["type"]
    assert_equal %w[Mars Venus], c["options"]
    assert_equal "Pick a planet", c["original_text"]
  end

  test "checkbox → select_many" do
    c = cards.find { |x| x["text"] == "Which do you like?" }
    assert_equal "select_many", c["type"]
    assert_equal %w[Stars Moons], c["options"]
  end

  test "0–10 scale → nps, short scale → range" do
    nps = cards.find { |x| x["text"] == "How likely to recommend?" }
    assert_equal "nps", nps["type"]
    assert_equal %w[0 1 2 3 4 5 6 7 8 9 10], nps["options"]

    rng = cards.find { |x| x["text"] == "Rate the mission" }
    assert_equal "range", rng["type"]
    assert_equal %w[1 2 3 4 5], rng["options"]
  end

  # A Verto range is always a 5-point scale, so a Form's 1–4 or 1–7 linear
  # scale is re-cut to five consecutive numbers from its own start rather than
  # importing a 4-point slider with no true centre.
  test "a linear scale that isn't 5 points is re-cut to 5, keeping its start" do
    scale = ->(low, high) do
      GoogleFormsImporter.call({
        "info"  => { "title" => "S" },
        "items" => [ { "title" => "How much?", "questionItem" => { "question" => {
          "scaleQuestion" => { "low" => low, "high" => high }
        } } } ]
      })["cards"].find { |c| c["type"] == "range" }
    end

    assert_equal %w[1 2 3 4 5], scale.call(1, 4)["options"], "a 1–4 scale should grow to 1–5"
    assert_equal %w[0 1 2 3 4], scale.call(0, 3)["options"], "a 0–3 scale should keep its zero"
    assert_equal %w[1 2 3 4 5], scale.call(1, 7)["options"], "a 1–7 scale should shrink to 1–5"
  end

  test "rating → rating and text → open_ended" do
    assert_equal "rating", cards.find { |x| x["text"] == "Star rating" }["type"]
    assert_equal "open_ended", cards.find { |x| x["text"] == "Anything else?" }["type"]
  end

  test "date question → open_ended with a date input" do
    c = cards.find { |x| x["text"] == "When were you born?" }
    assert_equal "open_ended", c["type"]
    assert_equal "date", c["input"]
  end

  test "file upload and non-question items are skipped" do
    assert_nil cards.find { |x| x["text"] == "Upload a drawing" }
    assert_nil cards.find { |x| x["text"] == "A section header" }
  end

  test "a grid expands to one choice question per row, sharing the columns" do
    rows = cards.select { |x| x["text"].start_with?("Rate these — ") }
    assert_equal 2, rows.size
    assert_equal [ "Rate these — Rockets", "Rate these — Aliens" ], rows.map { |r| r["text"] }
    rows.each do |r|
      assert_equal "multiple_choice", r["type"]
      assert_equal %w[Good Bad], r["options"]
    end
  end

  test "handles an empty/garbage form without raising" do
    assert_equal({ "title" => nil, "description" => nil, "cards" => [] }, GoogleFormsImporter.call(nil))
    assert_equal [], GoogleFormsImporter.call({ "items" => [ {} ] })["cards"]
  end
end
