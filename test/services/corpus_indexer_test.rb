require "test_helper"

# What crosses the organisation boundary, and what must not.
#
# Two of these tests guard failure modes that are silent — the kind that ship,
# get cited in a funder's report, and are only noticed by someone who happens to
# know the data:
#
#   * prioritise counts are SUMS OF RANKS, not frequencies. Indexed as counts,
#     every prioritise citation is confidently wrong with no visible symptom.
#   * a suppressed cell must be ABSENT, not zero. A published "0" says nobody in
#     that group answered that way, which in a small group is a statement about
#     named people.
class CorpusIndexerTest < ActiveSupport::TestCase
  # Themes and quotes need a Claude call; every test here is about the numbers,
  # so the themer is a stub that returns nothing.
  class NullThemer
    def call(**) = { themes: [], quotes: [] }
  end

  def setup
    @org = Organisation.create!(name: "O", slug: "ci-#{SecureRandom.hex(3)}")
  end

  def survey_with(cards)
    @org.surveys.create!(title: "S", theme: "Climate", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards)
  end

  # n completed responses, each answering card 0 with the value yielded.
  def seed!(survey, n)
    n.times do |i|
      survey.responses.create!(
        session_token: SecureRandom.hex(8), status: "completed",
        answers: yield(i)
      )
    end
  end

  def index!(survey)
    entry = CorpusEntry.create!(survey: survey, organisation: @org,
                                opted_in_at: Time.current, review_status: "approved")
    CorpusIndexer.new(entry, themer: NullThemer.new).call
    entry.reload
  end

  # ── The prioritise trap ───────────────────────────────────────────────────
  test "prioritise is stored as a mean rank, never as counts" do
    survey = survey_with([ { "type" => "prioritise", "cid" => "c_p", "text" => "Rank these",
                             "options" => [ "Money", "Time", "Info" ] } ])
    # Everyone ranks Money first, Time second, Info third. As RANK SUMS that is
    # Money 40, Time 80, Info 120 for 40 respondents — numbers that look exactly
    # like counts and mean the opposite (lower = more important).
    seed!(survey, 40) { { "0" => { "value" => [ "Money", "Time", "Info" ] } } }

    entry = index!(survey)
    question = entry.corpus_questions.find_by(cid: "c_p")

    assert_not_nil question
    assert_equal %w[mean_rank], question.distribution.keys,
      "a prioritise distribution must expose ONLY mean_rank — a counts key would be read as a frequency"
    assert_in_delta 1.0, question.distribution["mean_rank"]["Money"], 0.01
    assert_in_delta 2.0, question.distribution["mean_rank"]["Time"], 0.01
    assert_in_delta 3.0, question.distribution["mean_rank"]["Info"], 0.01
    # The raw rank sums (40, 80, 120) must not survive anywhere.
    assert_not_includes question.distribution.to_json, "120"
  end

  test "contact_form is never indexed" do
    survey = survey_with([ { "type" => "contact_form", "cid" => "c_cf", "text" => "Stay in touch" } ])
    seed!(survey, 40) { { "0" => { "value" => { "name" => "Real Person", "email" => "a@b.com" } } } }

    entry = index!(survey)

    assert_empty entry.corpus_questions
    assert_not_includes entry.corpus_questions.to_json, "a@b.com"
  end

  # ── Sample floors ─────────────────────────────────────────────────────────
  test "a Verto under the sample floor indexes nothing" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, CorpusEntry::MIN_SAMPLE_SIZE - 1) { { "0" => { "value" => "Yes" } } }

    entry = index!(survey)

    assert_empty entry.corpus_questions
    assert_equal CorpusEntry::MIN_SAMPLE_SIZE - 1, entry.response_count
    assert_not_nil entry.indexed_at, "it was still looked at — that is not the same as never indexed"
  end

  test "a question answered by too few people is left out even when the Verto clears the floor" do
    survey = survey_with([
      { "type" => "yes_no", "cid" => "c_answered", "text" => "Everyone answers", "options" => %w[Yes No] },
      { "type" => "yes_no", "cid" => "c_skipped",  "text" => "Almost nobody does", "options" => %w[Yes No] }
    ])
    seed!(survey, 40) do |i|
      answers = { "0" => { "value" => "Yes" } }
      answers["1"] = { "value" => "No" } if i < 3
      answers
    end

    entry = index!(survey)

    assert_equal [ "c_answered" ], entry.corpus_questions.pluck(:cid)
  end

  test "falling below the floor on re-index removes what was there" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, 40) { { "0" => { "value" => "Yes" } } }
    entry = index!(survey)
    assert_equal 1, entry.corpus_questions.count

    survey.responses.limit(20).destroy_all
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    assert_empty entry.reload.corpus_questions
  end

  # ── Citation stability ────────────────────────────────────────────────────
  test "re-indexing keeps a question's id, because the id IS the citation" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => %w[Yes No] } ])
    seed!(survey, 40) { { "0" => { "value" => "Yes" } } }
    entry = index!(survey)
    original_id = entry.corpus_questions.first.id

    seed!(survey, 5) { { "0" => { "value" => "No" } } }
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    question = entry.reload.corpus_questions.first
    assert_equal original_id, question.id,
      "a delete-and-recreate would silently re-point every citation already stored on an answered message"
    assert_equal 45, question.response_count
  end

  test "a question deleted from the deck leaves the corpus" do
    survey = survey_with([
      { "type" => "yes_no", "cid" => "c_a", "text" => "Keep", "options" => %w[Yes No] },
      { "type" => "yes_no", "cid" => "c_b", "text" => "Drop", "options" => %w[Yes No] }
    ])
    seed!(survey, 40) { { "0" => { "value" => "Yes" }, "1" => { "value" => "No" } } }
    entry = index!(survey)
    assert_equal 2, entry.corpus_questions.count

    survey.update!(cards: [ Array(survey.cards).first ])
    CorpusIndexer.new(entry, themer: NullThemer.new).call

    assert_equal [ "c_a" ], entry.reload.corpus_questions.pluck(:cid)
  end

  # ── Readability of what is stored ─────────────────────────────────────────
  # Range cards are always a 5-point scale (Survey::RANGE_POINTS) — a 4-option
  # card has a centre inserted on save, which shifts every label after it. The
  # indexer therefore reads the STORED options, and this test uses five so the
  # labels it asserts are the ones a respondent actually saw.
  test "range steps are stored as their labels, not as indexes" do
    survey = survey_with([ { "type" => "range", "cid" => "c_r", "text" => "How worried?",
                             "options" => [ "Not at all", "Not very", "Neutral", "Somewhat", "Very" ] } ])
    seed!(survey, 40) { |i| { "0" => { "value" => i < 30 ? 3 : 4 } } }

    entry = index!(survey)
    dist = entry.corpus_questions.find_by(cid: "c_r").distribution

    assert_equal 30, dist["Somewhat"]
    assert_equal 10, dist["Very"]
    assert_not dist.key?("3"), "a citation must read 'Somewhat', never 'step 3'"
  end

  test "rating keeps its average alongside the counts" do
    survey = survey_with([ { "type" => "rating", "cid" => "c_rt", "text" => "Rate it" } ])
    seed!(survey, 40) { |i| { "0" => { "value" => i.even? ? 4 : 2 } } }

    dist = index!(survey).corpus_questions.find_by(cid: "c_rt").distribution

    assert_in_delta 3.0, dist["avg"], 0.01
    assert_equal 20, dist["4"]
  end

  test "ranked_options turns a distribution into ordered shares" do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { |i| { "0" => { "value" => i < 30 ? "Money" : "Time" } } }

    ranked = index!(survey).corpus_questions.find_by(cid: "c_m").ranked_options

    assert_equal "Money", ranked.first[:label]
    assert_in_delta 75.0, ranked.first[:percent], 0.01
    assert_in_delta 25.0, ranked.last[:percent], 0.01
  end

  # ── Segments ──────────────────────────────────────────────────────────────
  # A programme run twice — digitally and on paper — is one study whose halves
  # are worth comparing. Merging them into one Verto is what lets Ask Verto cite
  # the combined sample; this dimension is what stops that merge losing the
  # comparison.
  test "collection mode becomes a breakdown when a Verto was run more than one way" do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => "Money" } } }
    survey.responses.limit(40).update_all(collection_mode: "digital")
    seed!(survey, 35) { { "0" => { "value" => "Time" } } }
    survey.responses.where(collection_mode: nil).update_all(collection_mode: "paper")

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert segments.key?("Collected: digital")
    assert segments.key?("Collected: paper")
    assert_equal 40, segments["Collected: digital"]["n"]
    assert_equal 35, segments["Collected: paper"]["n"]
    assert_equal 40, segments["Collected: digital"]["distribution"]["Money"]
  end

  test "an ordinary Verto gets no collection-mode breakdown at all" do
    # Every response came through the player, so the column is NULL and the
    # dimension must simply not appear — not appear as one meaningless cell.
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => "Money" } } }

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert(segments.keys.none? { |k| k.start_with?("Collected:") })
  end

  test "a collection mode under the floor is suppressed like any other cell" do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    seed!(survey, 40) { { "0" => { "value" => "Money" } } }
    survey.responses.limit(40).update_all(collection_mode: "digital")
    seed!(survey, 5) { { "0" => { "value" => "Time" } } }
    survey.responses.where(collection_mode: nil).update_all(collection_mode: "paper")

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert segments.key?("Collected: digital")
    assert_not segments.key?("Collected: paper"),
      "a mode with 5 respondents describes individuals, not a cohort"
  end

  test "a segment cell under the floor is absent, not zero" do
    survey = survey_with([ { "type" => "multiple_choice", "cid" => "c_m", "text" => "Why?",
                             "options" => [ "Money", "Time" ] } ])
    # 40 women (clears 30), 5 men (does not).
    seed!(survey, 40) { { "0" => { "value" => "Money" }, "_g" => nil } }
    survey.responses.limit(40).update_all(demographic_gender: "Female")
    seed!(survey, 5) { { "0" => { "value" => "Time" } } }
    survey.responses.where(demographic_gender: nil).update_all(demographic_gender: "Male")

    segments = index!(survey).corpus_questions.find_by(cid: "c_m").segments

    assert segments.key?("Gender: Female")
    assert_not segments.key?("Gender: Male"),
      "a published zero is as identifying as a published one — the cell must be absent"
  end
end
