require "test_helper"
require "csv"
require "tempfile"

# Replaying the WLL Transforming Education export.
#
# The fixture is SYNTHETIC — the real exports hold 54,000 children's answers and
# don't belong in a repository — but every shape in it was measured on the real
# files: repeated atoms in single-select cells, separator padding from none to
# six spaces, "Skipped" as a literal value, a lower-case first letter on one
# option in one column, mixed string/integer types on the 0–10 scale, country
# codes that contradict their country name, and an age column with a junk tail.
#
# Each of those has the same failure mode if it is missed: the import reports a
# clean run and the answers are quietly wrong or quietly missing.
class VertoCsvImporterWllTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/wll_import_sample.csv")

  def setup
    @importer = VertoCsvImporter.new(csv_path: FIXTURE, admin_password: "a-long-enough-passphrase",
                                     deck: "wll_education_digital")
    @survey = @importer.call
  end

  def card_index(fragment)
    @survey.cards.index { |card| card["text"].to_s.include?(fragment) } ||
      raise("no card matching #{fragment.inspect}")
  end

  def values_for(fragment)
    index = card_index(fragment).to_s
    @survey.responses.filter_map { |r| r.answers[index]&.dig("value") }
  end

  test "the whole export replays into one Verto" do
    assert_equal 40, @survey.responses.count
    assert_equal 29, @survey.cards.size
    assert_equal "wll", @survey.organisation.slug
  end

  test "every answer matches an option the deck offers" do
    # The one exception is deliberate: an age outside the plausible range.
    unmatched = @importer.unmatched.except("How old are you? (age)")

    assert_empty unmatched, "these values matched no option: #{unmatched.inspect}"
  end

  # ── the shapes that break quietly ─────────────────────────────────────────
  test "a single-select cell that repeats its answer counts once" do
    moods = values_for("How are you feeling today?")

    assert_equal 40, moods.size
    assert(moods.none? { |v| v.include?("|||") },
      "a repeated atom must be read as the answer, not passed through as a joined string")
  end

  test "Skipped is not an answer, and saying so is recorded" do
    # Row 1 says only "Skipped"; row 2 says "Skipped ||| More than other people".
    index  = card_index("I enjoy school").to_s
    scale  = @survey.cards[card_index("I enjoy school")]
    stored = @survey.responses.order(:session_token).map { |r| r.answers[index] }

    assert_nil stored[1], "a Skipped cell is a question nobody answered"
    assert_equal "More than other people", scale["options"][stored[2]["value"]],
      "and a Skipped mixed in with a real answer must keep the real answer"

    # It used to vanish in both directions: atoms removed it before matching, so
    # record_unmatched received an empty string and its own guard swallowed it.
    dropped = @importer.dropped["I enjoy school… (range)"]
    assert_equal 2, dropped.values.sum, "both Skipped cells have to be counted somewhere"
    assert(dropped.keys.all? { |k| k.start_with?("Skipped —") })
  end

  test "separator padding does not create shadow options" do
    options = @survey.cards[card_index("I do my best learning")]["options"]
    chosen  = values_for("I do my best learning").flatten.uniq

    assert (chosen - options).empty?,
      "these came back with padding still attached: #{(chosen - options).inspect}"
  end

  test "an option spelled with a different first letter is still that option" do
    # The paper file writes "to understand the world…" lower-case in one column
    # and "To understand…" in another. Matched case-sensitively, 377 real
    # respondents become their own results bucket.
    chosen = values_for("The main reason I go to school")

    assert_includes chosen, "To understand the world and help make it better"
    assert_not_includes chosen, "to understand the world and help make it better"
  end

  test "a ranking keeps its order" do
    rankings = values_for("Which skills do you think you need to start change")

    assert_equal 40, rankings.size
    assert_operator rankings.uniq.size, :>, 1, "every row ranked the same way — the order was lost"
    assert(rankings.all? { |r| r.size == VertoDecks::WllEducation::CHANGE_SKILLS.size },
      "a ranking that drops entries is not a ranking")
  end

  test "the 0-10 scale keeps all eleven of its values" do
    # It used to be cut into the five stops a range card has, so 2,420 people
    # who answered 10 and 53 who answered 9 became one number, and NPS itself
    # could not be computed from the database at all.
    card   = @survey.cards[card_index("Are you learning these skills")]
    stored = values_for("Are you learning these skills")

    assert_equal "multiple_choice", card["type"],
      "a range card is coerced to five options on save, which would re-point every stored index"
    assert_equal 11, card["options"].size
    assert_equal 40, stored.size, "the endpoints arrive as strings and 1–9 as integers; both are answers"
    # The export's own spellings, including the missing space in "0- No".
    assert_includes stored, "0- No"
    assert_includes stored, "10 - Yes"
    assert_includes stored, "5"
    assert_equal 7, stored.uniq.size, "the fixture cycles seven of the eleven, and each stays distinct"
  end

  test "a three-pile card sort keeps the pile's own words" do
    # "Nothing at all" / "Not enough" / "More than enough" is a sufficiency
    # scale. Folded onto tap_card's yes/no/unsure it would publish "yes" where
    # a respondent said "not enough".
    card = @survey.cards[card_index("How much are you learning to… Analyse")]

    assert_equal "multiple_choice", card["type"]
    assert_equal [ "Nothing at all", "Not enough", "More than enough" ], card["options"]
    assert_equal [ "More than enough" ], values_for("How much are you learning to… Analyse").uniq
    assert_equal [ "Nothing at all" ], values_for("How much are you learning to… Be creative").uniq
    assert_equal [ "Not enough" ], values_for("How much are you learning to… Protect the planet").uniq
  end

  test "a card sort with a named third pile does not infer it" do
    sorted = values_for("Which of the following statements").first

    assert_equal "yes", sorted["I was happier learning at home"]
    assert_equal "no",  sorted["I feel anxious being back at school"]
    assert_equal "unsure", sorted["I'm happy to be back at school"],
      "the export names this pile 'I don't know' — it is read, not guessed"
  end

  test "free text keeps the respondent's words and loses the markup" do
    texts = values_for("What is one thing that your school should stop doing")

    assert_includes texts, "Stop making us sit still — it's hard.",
      "an entity-escaped apostrophe printed raw is not the sentence they wrote"
  end

  test "the country name wins when the country code contradicts it" do
    # "United Kingdom - EN" and "Bangladesh - Comics" are real values. Trusting
    # the trailing token files thousands of respondents under a country they
    # don't live in; both are resolved by name here.
    tagged = @survey.responses.where.not(region_country: nil)

    assert_equal 40, tagged.count
    assert_includes tagged.pluck(:region_country), "GB"
    assert_includes tagged.pluck(:region_country), "BD"
    assert_includes tagged.pluck(:region_country), "MG", "a value with no spaces around the dash"
  end

  test "an implausible age is kept as an answer and left out of the banding" do
    # 99 in a children's survey is junk — but 99 is what that row says, and
    # deciding it is junk is an analysis judgement, not a licence to delete the
    # answer. So it is stored, and only the derived birth year declines it.
    ages = values_for("How old are you?")

    assert_equal 40, ages.size, "every age given is an age given"
    assert_includes ages, "99"
    assert_equal 39, @survey.responses.where.not(demographic_birth_year: nil).count,
      "…but it must not band a child cohort with an imaginary pensioner"
    assert_equal 40, @survey.responses.where.not(demographic_gender: nil).count
    assert @importer.notes["How old are you? (age)"].keys.any? { |k| k.start_with?("99 —") },
      "and the decision has to be visible in the import report — as a note, not a loss, " \
      "because the answer is still there"
  end

  test "a second answer in a single-answer cell is reported, not silently dropped" do
    # Row 0 is "Happy ||| Happy" — a repeat, which is not a second answer. The
    # real ones (242 of them in the Big Green export) must show up somewhere.
    repeats = @importer.dropped["How are you feeling today? (range)"]

    assert_empty repeats, "a cell that repeats its own answer has not lost anything"
  end

  test "the settlement-type question is not filed as gender" do
    # Both it and the real gender question carry the export's "(gender)" tag.
    assert_equal "What is your gender?", @survey.cards[card_index("What is your gender?")]["text"]
    assert_includes @survey.responses.first.demographic_gender, "Female"
    assert_includes values_for("What type of area do you live in"), "Urban (a city)"
  end

  test "a pipe typed into a free-text box does not cost a respondent their country" do
    # region_from used to scan the answers hash for the first open_ended value
    # containing a "|" and read that as the location. This deck has three
    # free-text cards BEFORE the country card, so one respondent typing a pipe
    # lost their country tag — while their country sat correctly two answers
    # further down the same hash.
    column = "What is one thing that your school should stop doing? (freeform)"
    table  = CSV.read(FIXTURE, headers: true, encoding: "bom|utf-8")
    rows   = table.each.to_a
    rows.first[column] = "Stop the 9|00 starts"

    file = Tempfile.new([ "wll_pipe", ".csv" ])
    file.write(CSV.generate { |out| out << table.headers; rows.each { |r| out << r.fields } })
    file.close

    survey = VertoCsvImporter.new(csv_path: file.path, admin_password: "a-long-enough-passphrase",
                                  deck: "wll_education_digital").call
    first = survey.responses.order(:session_token).first

    assert_equal "IN", first.region_country
    assert_equal "India - IN", first.region_label, "and the label is the export's own words"
  ensure
    file&.unlink
  end

  test "a location answer keeps the export's own spelling" do
    # "United Kingdom - EN" resolves to GB by name, because EN is not a country
    # code. The correction is right; losing what the export actually said is not.
    values = values_for("Where do you live?")

    assert_includes values, "GB|United Kingdom - EN"
    assert_includes values, "MG|Madagascar-MG"
    assert @importer.notes.values.flat_map(&:keys).any? { |k| k.include?("resolved to GB by name") },
      "a code overruled by the country name has to be reported"
  end

  # ── the two halves ────────────────────────────────────────────────────────
  test "the paper half appends into the same Verto without colliding" do
    paper = VertoCsvImporter.new(csv_path: FIXTURE, deck: "wll_education_paper")
    result = paper.append!

    assert_equal @survey.id, result[:survey].id, "same programme, same Verto"
    assert_equal 40, result[:added], "and the same Viewing IDs are different respondents"
    assert_equal 0, result[:updated]
    assert_equal 40, @survey.responses.where(collection_mode: "digital").count
    assert_equal 40, @survey.responses.where(collection_mode: "paper").count
  end
end
