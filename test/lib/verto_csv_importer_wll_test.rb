require "test_helper"

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

  test "Skipped is not an answer" do
    # Row 1 says only "Skipped"; row 2 says "Skipped ||| More than other people".
    index  = card_index("I enjoy school").to_s
    scale  = @survey.cards[card_index("I enjoy school")]
    stored = @survey.responses.order(:session_token).map { |r| r.answers[index] }

    assert_nil stored[1], "a Skipped cell is a question nobody answered"
    assert_equal "More than other people", scale["options"][stored[2]["value"]],
      "and a Skipped mixed in with a real answer must keep the real answer"
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

  test "the 0-10 scale reads its string endpoints and its integer middle alike" do
    scale  = @survey.cards[card_index("Are you learning these skills")]
    stored = values_for("Are you learning these skills")

    assert_equal 40, stored.size, "the endpoints arrive as strings and 1–9 as integers; both are answers"
    assert_includes stored.map { |v| scale["options"][v] }, "Not at all (0–2)"
    assert_includes stored.map { |v| scale["options"][v] }, "Yes, definitely (9–10)"
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

  test "an implausible age is dropped rather than banded" do
    ages = values_for("How old are you?")

    assert_equal 39, ages.size, "the 99 is junk, and one junk answer must not cost the whole row"
    assert_equal 39, @survey.responses.where.not(demographic_birth_year: nil).count
    assert_equal 40, @survey.responses.where.not(demographic_gender: nil).count
  end

  test "the settlement-type question is not filed as gender" do
    # Both it and the real gender question carry the export's "(gender)" tag.
    assert_equal "What is your gender?", @survey.cards[card_index("What is your gender?")]["text"]
    assert_includes @survey.responses.first.demographic_gender, "Female"
    assert_includes values_for("What type of area do you live in"), "Urban (a city)"
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
