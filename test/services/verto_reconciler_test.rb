require "test_helper"

# The check that makes "the import changed nothing" checkable.
#
# For every question column the arithmetic has to close:
#
#     source + inferred == stored + reported
#
# The source side is read as raw text, never through the deck, so a spec that
# loses an answer cannot also hide it from the count. These tests break the
# identity on purpose, one term at a time, and assert that it notices.
class VertoReconcilerTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/wll_import_sample.csv")

  def setup
    @importer = VertoCsvImporter.new(csv_path: FIXTURE, admin_password: "a-long-enough-passphrase",
                                     deck: "wll_education_digital")
    @survey = @importer.call
  end

  def report(importer = nil)
    importer ||= VertoCsvImporter.new(csv_path: FIXTURE, deck: "wll_education_digital")
    VertoReconciler.new(importer, @survey).call
  end

  test "a faithful import reconciles" do
    result = report

    assert result.clean?, "unaccounted: #{result.problems.map { |l| "#{l.column} #{l.difference}" }.join(', ')}"
    assert_equal 40, result.rows
    assert_equal 40, result.responses
  end

  test "every question column is checked, none silently skipped" do
    # A column whose spec resolved to nil would vanish from the report rather
    # than fail it, which is the quietest way for this check to stop checking.
    columns = report.lines.flat_map { |line| line.column.split(" + ") }

    assert_includes columns, "Where do you live? Type your country &amp; choose from the drop down (location)"
    assert_includes columns, "Which skills do you think you need to start change?&nbsp; (priority)"
    assert_equal 21, report.lines.size
  end

  test "a card sort's three piles are one line, not three" do
    # Eight statement cards read the same three columns. Counted per card, the
    # source would be multiplied eightfold and the check would report a
    # shortfall that does not exist.
    line = report.lines.find { |l| l.column.include?("decision - Nothing at all") }

    assert_equal 3, line.column.split(" + ").size
    assert line.clean?
  end

  test "an answer deleted from the Verto is caught" do
    @survey.responses.first.then { |r| r.update!(answers: r.answers.except("1")) }

    result = report

    assert_not result.clean?
    assert_equal 1, result.problems.sum(&:difference),
      "one answer removed from the Verto is one answer the export still holds"
  end

  test "an answer the deck silently swallowed is caught" do
    # The failure this exists for: a spec that drops a value and records
    # nothing. Simulated by clearing the ledger the import wrote.
    assert report.clean?

    mute = VertoCsvImporter.new(csv_path: FIXTURE, deck: "wll_education_digital")
    mute.define_singleton_method(:record_dropped) { |*| nil }
    broken = VertoReconciler.new(mute, @survey).call

    assert_not broken.clean?, "with nothing reported, every deliberate omission has to read as a loss"
    assert_operator broken.problems.sum(&:difference), :>, 0
  end

  test "free text is never split on the separator" do
    # 216 cells in one export contain a literal "|||" the respondent typed.
    # Split, one answer would count as several and the column would never
    # reconcile again.
    line = report.lines.find { |l| l.column.start_with?("What is one thing") }

    assert line.clean?
    assert_equal @survey.responses.count { |r| r.answers.key?("8") }, line.source
  end
end
