require "test_helper"

# CorpusTools is the one place in the app that reads across organisation
# boundaries, so the thing worth testing hardest is what it CANNOT see.
#
# Every test here creates data that exists, is relevant, and matches the search
# — and then asserts the tools return nothing, because one of the two consent
# gates is not open. A leak in this class is a leak of another company's data.
class CorpusToolsTest < ActiveSupport::TestCase
  def setup
    @org = Organisation.create!(name: "Anglo American Foundation", slug: "ct-#{SecureRandom.hex(3)}")
  end

  def indexed_verto(title: "Valparaíso Youth Pulse", opted_in: true, withdrawn: false,
                    review_status: "approved", question: "How worried are you about climate change?")
    survey = @org.surveys.create!(title: title, theme: "Climate Action", audience_age: "all",
                                  key_insight: "x", default_locale: "en", locales: [ "en" ],
                                  cards: [ { "type" => "multiple_choice", "cid" => "c_#{SecureRandom.hex(2)}",
                                             "text" => question,
                                             "options" => [ "Very worried", "Somewhat worried", "Not worried" ] } ])
    40.times do |i|
      survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                               answers: { "0" => { "value" => i < 30 ? "Very worried" : "Not worried" } })
    end

    entry = CorpusEntry.create!(survey: survey, organisation: @org, review_status: "approved",
                                opted_in_at: 1.day.ago)
    CorpusIndexer.new(entry, themer: null_themer).call

    entry.update!(review_status: review_status)
    entry.update!(opted_in_at: nil) unless opted_in
    entry.update!(withdrawn_at: Time.current) if withdrawn
    entry.reload
  end

  def null_themer
    Class.new { def call(**) = { themes: [], quotes: [] } }.new
  end

  def search(query = "climate")
    CorpusTools.new.call("search_corpus", { "query" => query })
  end

  # ── What must not be visible ──────────────────────────────────────────────
  test "a Verto awaiting review is invisible to search" do
    indexed_verto(review_status: "pending")
    assert_empty search[:questions]
  end

  test "a declined Verto is invisible to search" do
    indexed_verto(review_status: "declined")
    assert_empty search[:questions]
  end

  test "a withdrawn Verto is invisible even though we approved it" do
    entry = indexed_verto(withdrawn: false)
    assert_equal 1, search[:questions].size

    entry.withdraw!

    assert_empty search[:questions],
      "withdrawal is a read-time filter — there must be no window where it still answers"
  end

  test "a Verto whose creator never opted in is invisible even though we approved it" do
    indexed_verto(opted_in: false)
    assert_empty search[:questions]
  end

  test "get_questions refuses an id from a Verto that is not citable" do
    entry = indexed_verto
    id = entry.corpus_questions.first.id
    assert_equal 1, CorpusTools.new.call("get_questions", { "ids" => [ id ] })[:results].size

    entry.withdraw!

    result = CorpusTools.new.call("get_questions", { "ids" => [ id ] })
    assert result[:error].present?, "a known id must stop resolving the moment consent is withdrawn"
  end

  test "a stamped source carries the survey's SDG tags for the rail" do
    entry = indexed_verto
    entry.survey.update_column(:sdgs, [ 4, 13 ])
    id = entry.corpus_questions.first.id

    tools = CorpusTools.new
    tools.call("get_questions", { "ids" => [ id ] })

    assert_equal [ 4, 13 ], tools.sources.first["sdgs"],
      "the source snapshot is what the rail, the citation record and the replay all read"
  end

  test "a stamped source carries its answer breakdown for the Detail pane" do
    entry = indexed_verto
    tools = CorpusTools.new
    tools.call("get_questions", { "ids" => [ entry.corpus_questions.first.id ] })

    breakdown = tools.sources.first["breakdown"]
    assert_equal "Very worried", breakdown.first["label"]
    assert_equal 30, breakdown.first["count"]
    assert_in_delta 75.0, breakdown.first["percent"], 0.01
  end

  test "a prioritise source carries no breakdown — a rank is not a count" do
    survey = @org.surveys.create!(title: "P", theme: "T", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ],
                                  cards: [ { "type" => "prioritise", "cid" => "c_p", "text" => "Rank these",
                                             "options" => %w[Money Time] } ])
    40.times do
      survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                               answers: { "0" => { "value" => %w[Money Time] } })
    end
    entry = CorpusEntry.create!(survey: survey, organisation: @org, review_status: "approved",
                                opted_in_at: 1.day.ago)
    CorpusIndexer.new(entry, themer: null_themer).call

    tools = CorpusTools.new
    tools.call("get_questions", { "ids" => [ entry.corpus_questions.first.id ] })

    assert_empty tools.sources.first["breakdown"],
      "bars over mean ranks would read as shares of people — the misreading result_row warns against"
  end

  test "an SDG a citable survey declares becomes a suggestion tile in the goal's colour" do
    entry = indexed_verto
    entry.survey.update_column(:sdgs, [ 13 ])

    suggestion = CorpusTools.new.suggestions.find { |s| s[:icon] == "13" }

    assert suggestion, "a declared goal with citable data behind it should be offered"
    assert_equal UnSdgs.color(13), suggestion[:accent]
    assert_includes suggestion[:question], UnSdgs.title(13)
    assert_includes suggestion[:meta], "SDG 13"
  end

  test "a withdrawn Verto's SDGs leave the suggestions with it" do
    entry = indexed_verto
    entry.survey.update_column(:sdgs, [ 13 ])
    entry.withdraw!

    assert_nil CorpusTools.new.suggestions.find { |s| s[:icon] == "13" },
      "suggestions are a disclosure — a withdrawn Verto's goals must not survive on the front page"
  end

  test "list_vertos shows only citable Vertos" do
    indexed_verto(title: "Live one")
    indexed_verto(title: "Pending one", review_status: "pending")

    names = CorpusTools.new.call("list_vertos", {})[:vertos].map { |v| v[:verto] }

    assert_equal [ "Live one" ], names
  end

  # The theme filter once went through joins+DISTINCT over full corpus_entries
  # rows, which Postgres refuses on a table with json columns — every themed
  # listing in production returned "That lookup failed" while SQLite passed.
  test "list_vertos filters by theme without tripping over json columns" do
    indexed_verto(title: "Climate one")

    rows = CorpusTools.new.call("list_vertos", { "theme" => "climate" })

    assert_nil rows[:error]
    assert_equal [ "Climate one" ], rows[:vertos].map { |v| v[:verto] }
    assert_empty CorpusTools.new.call("list_vertos", { "theme" => "biodiversity" })[:vertos]
  end

  # Same production-only failure shape: LOWER() over the json options column
  # needs an explicit text cast on Postgres. The match must actually work —
  # "somewhat" appears in an option label and nowhere else on the question.
  test "search matches inside answer options across databases" do
    indexed_verto

    rows = search("somewhat")

    assert_nil rows[:error]
    assert_equal 1, rows[:questions].size
  end

  test "coverage counts only what can be cited" do
    indexed_verto(title: "Live one")
    indexed_verto(title: "Pending one", review_status: "pending")

    assert_equal 1, CorpusTools.new.coverage[:vertos]
  end

  # ── Stamping is what makes a citation possible ────────────────────────────
  test "search returns no numbers, so a source can only be stamped by fetching" do
    indexed_verto
    tools = CorpusTools.new
    row = tools.call("search_corpus", { "query" => "climate" })[:questions].first

    assert_nil row[:answers], "a search result must not carry results — fetching is what stamps a source"
    assert_empty tools.sources
  end

  test "fetching stamps a source number and records what it points at" do
    entry = indexed_verto
    tools = CorpusTools.new
    id = entry.corpus_questions.first.id

    row = tools.call("get_questions", { "ids" => [ id ] })[:results].first

    assert_equal 1, row[:source]
    assert_equal 1, tools.sources.size
    assert_equal id, tools.sources.first["corpus_question_id"]
    assert_equal "Anglo American Foundation", tools.sources.first["organisation"]
    assert_equal 40, tools.sources.first["responses"]
  end

  test "the same question fetched twice keeps one source number" do
    entry = indexed_verto
    tools = CorpusTools.new
    id = entry.corpus_questions.first.id

    tools.call("get_questions", { "ids" => [ id ] })
    row = tools.call("get_questions", { "ids" => [ id ] })[:results].first

    assert_equal 1, row[:source]
    assert_equal 1, tools.sources.size
  end

  test "results carry percentages so the model never has to divide" do
    entry = indexed_verto
    id = entry.corpus_questions.first.id

    answers = CorpusTools.new.call("get_questions", { "ids" => [ id ] })[:results].first[:answers]

    assert_equal "Very worried", answers.first[:label]
    assert_in_delta 75.0, answers.first[:percent], 0.01
  end

  test "a prioritise result says in words that it is not a count" do
    survey = @org.surveys.create!(title: "P", theme: "T", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ],
                                  cards: [ { "type" => "prioritise", "cid" => "c_p", "text" => "Rank these",
                                             "options" => %w[Money Time] } ])
    40.times do
      survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                               answers: { "0" => { "value" => %w[Money Time] } })
    end
    entry = CorpusEntry.create!(survey: survey, organisation: @org, review_status: "approved",
                                opted_in_at: 1.day.ago)
    CorpusIndexer.new(entry, themer: null_themer).call

    row = CorpusTools.new.call("get_questions", { "ids" => [ entry.corpus_questions.first.id ] })[:results].first

    assert row[:reading].include?("not counts"), "a rank must never be handed over as if it were a count"
    assert_nil row[:answers]
    assert_in_delta 1.0, row[:mean_rank]["Money"], 0.01
  end

  # ── Presentation carried on a source ──────────────────────────────────────
  test "a stamped source carries its question type's accent and icon" do
    entry = indexed_verto
    tools = CorpusTools.new
    tools.call("get_questions", { "ids" => [ entry.corpus_questions.first.id ] })

    source = tools.sources.first
    assert_equal CardTypes.accent("multiple_choice"), source["accent"]
    assert_equal CardTypes.icon("multiple_choice"), source["icon"]
  end

  test "a source carries the Verto's own brand colour, separately from the type accent" do
    entry = indexed_verto
    entry.survey.update!(brand_palette: { "primary" => "#FF8800" })
    tools = CorpusTools.new
    tools.call("get_questions", { "ids" => [ entry.corpus_questions.first.id ] })

    source = tools.sources.first
    assert_equal "#FF8800", source["brand"], "the card says WHICH study"
    assert_equal CardTypes.accent("multiple_choice"), source["accent"], "the chip says WHAT KIND of evidence"
  end

  # ── Suggestions ───────────────────────────────────────────────────────────
  # These are shown on the empty screen before anyone has asked anything, so
  # they are a disclosure of what the corpus holds — theme names and counts.
  # They have to obey the same gate as every other read here.
  test "suggestions never name a theme from a Verto that is not citable" do
    entry = indexed_verto(question: "How worried are you about climate change?")
    entry.survey.update!(theme: "Secret Programme")
    entry.corpus_questions.update_all(theme: "Secret Programme")
    assert(CorpusTools.new.suggestions.any? { |s| s[:label] == "Secret Programme" } ||
           CorpusTools.new.suggestions.empty?)

    entry.withdraw!

    labels = CorpusTools.new.suggestions.map { |s| s[:label] }
    assert_not_includes labels, "Secret Programme",
      "a withdrawn Verto's themes must not survive on the front page"
  end

  test "an empty corpus offers nothing rather than inventing a starting point" do
    assert_empty CorpusTools.new.suggestions
  end

  test "a theme with only one question behind it is not offered" do
    # One card cannot be compared with anything — the suggestion would open onto
    # a recital, not a finding.
    indexed_verto
    themes = CorpusTools.new.suggestions.map { |s| s[:label] }

    assert_not_includes themes, "Climate Action"
  end

  test "a well-covered theme is offered, with its accent and a real count" do
    entry = indexed_verto
    # A second question on the same theme makes it comparable.
    entry.corpus_questions.create!(
      cid: "c_second", position: 1, card_type: "open_ended", theme: "Climate Action",
      question_text: "What would help you act?", response_count: 120,
      distribution: { "responses" => 120 }
    )

    suggestion = CorpusTools.new.suggestions.find { |s| s[:label] == "Climate Action" }

    assert_not_nil suggestion
    assert_includes suggestion[:question], "climate action"
    assert_match(/\A#[0-9A-Fa-f]{6}\z/, suggestion[:accent])
    assert_equal "2 questions", suggestion[:meta]
  end

  test "open text is offered only when the corpus has some" do
    entry = indexed_verto
    assert_empty CorpusTools.new.suggestions.select { |s| s[:icon] == CardTypes.icon("open_ended") }

    entry.corpus_questions.create!(
      cid: "c_open", position: 1, card_type: "open_ended", theme: "Climate Action",
      question_text: "What do you dream about?", response_count: 900,
      distribution: { "responses" => 900 }
    )

    own_words = CorpusTools.new.suggestions.find { |s| s[:icon] == CardTypes.icon("open_ended") }
    assert_not_nil own_words
    assert_equal CardTypes.accent("open_ended"), own_words[:accent]
  end

  test "suggestions are capped" do
    entry = indexed_verto
    10.times do |i|
      entry.corpus_questions.create!(
        cid: "c_#{i}", position: i + 1, card_type: "multiple_choice", theme: "Theme #{i % 5}",
        question_text: "Q#{i}", response_count: 100, distribution: { "A" => 100 }
      )
      entry.corpus_questions.create!(
        cid: "c_b#{i}", position: i + 20, card_type: "multiple_choice", theme: "Theme #{i % 5}",
        question_text: "Q b#{i}", response_count: 90, distribution: { "A" => 90 }
      )
    end

    assert_operator CorpusTools.new.suggestions.size, :<=, CorpusTools::MAX_SUGGESTIONS
  end

  # ── Behaviour under bad input ─────────────────────────────────────────────
  test "an unknown tool name is an error the model can recover from, not a raise" do
    assert_equal({ error: "Unknown tool nonsense." }, CorpusTools.new.call("nonsense", {}))
  end

  test "a search with no usable words asks for better ones" do
    assert_empty CorpusTools.new.call("search_corpus", { "query" => "a of" })[:questions]
  end

  test "an empty search says so rather than returning silence" do
    indexed_verto
    assert CorpusTools.new.call("search_corpus", { "query" => "aardvark" })[:note].present?
  end

  test "LIKE wildcards in a query cannot match everything" do
    indexed_verto
    assert_empty CorpusTools.new.call("search_corpus", { "query" => "%%%" })[:questions]
  end
end
