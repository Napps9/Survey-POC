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

  test "list_vertos shows only citable Vertos" do
    indexed_verto(title: "Live one")
    indexed_verto(title: "Pending one", review_status: "pending")

    names = CorpusTools.new.call("list_vertos", {})[:vertos].map { |v| v[:verto] }

    assert_equal [ "Live one" ], names
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
