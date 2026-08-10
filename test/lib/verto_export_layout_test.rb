require "test_helper"
require "csv"
require "stringio"

# Putting a shifted export's header back over the right columns.
#
# This guards the worst failure mode the importer has: VertoCsvImporter reads
# every column BY NAME, so an export whose header is one short doesn't fail — it
# succeeds and files every answer under the wrong question. A clean-looking
# import, a confidently wrong corpus. The assertions here are mostly about
# refusing to guess.
class VertoExportLayoutTest < ActiveSupport::TestCase
  ALIGNED   = Rails.root.join("test/fixtures/files/verto_import_sample.csv")
  SHIFTED   = Rails.root.join("test/fixtures/files/verto_import_shifted.csv")
  # The third shape, and the nastiest: a preamble shifted by one and questions
  # that are not, because a header with no data column ("Points") cancels the
  # unnamed data column out. Correcting the whole row here would misattribute
  # every answer — the same bug this class exists to prevent, one file over.
  PIECEWISE = Rails.root.join("test/fixtures/files/verto_import_piecewise.csv")

  def table(path) = CSV.read(path, headers: true, encoding: "bom|utf-8")

  test "an aligned export is left exactly as it is" do
    result = VertoExportLayout.realign(table(ALIGNED))

    assert_equal 0, result.shift
    assert_not result.realigned?
    assert_not result.piecewise?
    assert result.rows.all? { |row| row.is_a?(CSV::Row) },
      "downstream reads by name, so rows must stay CSV::Row"
  end

  test "a shifted export is detected and put back" do
    result = VertoExportLayout.realign(table(SHIFTED))

    assert_equal 1, result.shift
    assert_equal 1, result.tail_shift, "this file's shift really does run to the end"
    assert result.realigned?
    assert_not result.piecewise?
  end

  # ── the piecewise case ────────────────────────────────────────────────────
  test "a shift that stops before the questions is measured separately" do
    result = VertoExportLayout.realign(table(PIECEWISE))

    assert_equal 1, result.shift, "the preamble is shifted"
    assert_equal 0, result.tail_shift, "the questions are not"
    assert result.piecewise?
  end

  test "a piecewise export reads the same as an aligned one, preamble and questions alike" do
    aligned   = VertoExportLayout.realign(table(ALIGNED)).rows
    piecewise = VertoExportLayout.realign(table(PIECEWISE)).rows

    # Both halves of the row, because the whole point is that they moved by
    # different amounts. A single-shift correction passes the first list and
    # fails every entry in the second.
    [ "Completion percentage", "Position", "Language", "Viewing path",
      "In a typical week, how physically active are you? (range)",
      "Which types of sport do you take part in most often? (pickMany)",
      "What gender do you identify as? (gender)" ].each do |column|
      assert_equal aligned.map { |r| r[column].presence }, piecewise.map { |r| r[column].presence },
        "#{column} resolves to a different column once the layout is corrected"
    end
  end

  test "correcting a piecewise export as if it were a simple shift breaks the questions" do
    # The failure being guarded against, made explicit: with the preamble's
    # shift applied to the whole row, a question reads its neighbour's answer.
    headers = table(PIECEWISE).headers.map(&:to_s)
    naive   = VertoExportLayout.shifted_rows(table(PIECEWISE), headers, 1, 1)
    correct = VertoExportLayout.realign(table(PIECEWISE)).rows
    column  = "Which types of sport do you take part in most often? (pickMany)"

    assert_not_equal naive.map { |r| r[column].presence }, correct.map { |r| r[column].presence }
  end

  # The point of the whole class: the same lookups the importer makes must
  # return the same values from both files.
  test "the same column reads the same value shifted or not" do
    aligned = VertoExportLayout.realign(table(ALIGNED)).rows
    shifted = VertoExportLayout.realign(table(SHIFTED)).rows

    assert_equal aligned.size, shifted.size

    # Compared on presence: a row that stops early is written with trailing ""
    # in one copy and simply runs out in the other, so "" and nil are the same
    # answer — "they didn't get this far". The claim being made is about WHICH
    # column a name resolves to, not about CSV's padding.
    columns = [ "Language", "Position", "Viewing ID",
                # And a question column, which is what actually reaches the corpus.
                "In a typical week, how physically active are you? (range)" ]

    columns.each do |column|
      assert_equal aligned.map { |r| r[column].presence }, shifted.map { |r| r[column].presence },
        "#{column} resolves to a different column in the shifted copy — this is the misattribution bug"
    end
  end

  test "without realignment a shifted file reads the neighbouring column" do
    # Proves the bug is real rather than theoretical: read naively, the header
    # lands one column out.
    raw = table(SHIFTED).each.to_a
    naive = raw.first["Completion percentage"]
    fixed = VertoExportLayout.realign(table(SHIFTED)).rows.first["Completion percentage"]

    assert_not_equal naive, fixed
    assert_equal "True", naive, "naively, the completion percentage reads a consent flag"
    assert_match(/\A\d/, fixed.to_s, "realigned, it reads a number")
  end

  test "a file whose layout cannot be worked out is refused, not guessed at" do
    # Every probe column scrambled: no candidate shift can score. A misaligned
    # import is worse than no import.
    scrambled = table(ALIGNED)
    rows = scrambled.each.to_a.map do |row|
      CSV::Row.new(row.headers, row.fields.map { "???" })
    end
    fake = CSV::Table.new(rows)

    assert_raises(VertoExportLayout::AmbiguousLayout) { VertoExportLayout.realign(fake) }
  end

  test "the winning shift has to beat its rivals outright" do
    # A tie means the evidence doesn't distinguish the cases, which is exactly
    # when a wrong answer would be invisible.
    empty = CSV::Table.new([ CSV::Row.new(table(ALIGNED).headers, []) ])

    assert_raises(VertoExportLayout::AmbiguousLayout) { VertoExportLayout.realign(empty) }
  end

  # ── What it costs to decide ──────────────────────────────────────────────
  test "a file where nothing clears the fill bar is still decided on evidence" do
    # Every row is nearly empty, so none of them ever clears MIN_ROW_FILL. The
    # decision still has to be made on the rows that exist rather than on none.
    sparse = lambda do
      body = +"Viewing ID,Completion percentage,Position,Language,Viewing path\n"
      50.times { |i| body << "v#{i},100,1/1,en,\"[1]\"\n" }
      StringIO.new(body)
    end

    plan = VertoExportLayout.plan_from(&sparse)

    assert_equal 0, plan.shift
  end

  test "scoring rewards the shift that makes the preamble make sense" do
    headers = table(SHIFTED).headers.map(&:to_s)
    sample  = table(SHIFTED).first(20)

    assert_operator VertoExportLayout.score(headers, sample, 1), :>,
                    VertoExportLayout.score(headers, sample, 0)
  end
end
