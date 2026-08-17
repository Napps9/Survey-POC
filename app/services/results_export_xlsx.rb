require "caxlsx"

# Wraps ResultsExport's already-sanitized row stream into a single-sheet .xlsx
# workbook — the Excel-native alternative to the streamed CSV download, same
# `kind` (responses/summary), same formula-injection guard inherited from
# ResultsExport#each_row unchanged.
#
# Unlike the CSV path, a workbook can't be streamed row-by-row — Axlsx builds
# the whole thing in memory before serialisation. Fine at survey scale (the
# same data the CSV already holds server-side while generating each row), but
# don't move the CSV export onto this path.
class ResultsExportXlsx
  def initialize(export, summary:)
    @export  = export
    @summary = summary
  end

  # The finished .xlsx file's bytes.
  def to_stream
    package = Axlsx::Package.new
    sheet   = package.workbook.add_worksheet(name: @summary ? "Summary" : "Responses")

    header = true
    @export.each_row(summary: @summary) do |row|
      if header
        sheet.add_row(row, types: Array.new(row.size, :string))
        header = false
        next
      end
      # Counts, percentages, response IDs and durations stay real numbers
      # (nil lets Axlsx infer the Ruby type); every text cell is explicitly
      # :string — belt-and-braces on top of ResultsExport's own csv_safe
      # leading-quote guard, so a phone-number-like "+44…" answer, or any
      # future unsanitised path, still can't be read back as a formula. A
      # string-typed XLSX cell has no <f> formula element, so this is a
      # stronger guarantee than the CSV export's leading-quote escape (which
      # this inherits unchanged, and still shows, since it's part of the
      # string value already).
      sheet.add_row(row, types: row.map { |cell| cell.is_a?(Numeric) ? nil : :string })
    end

    package.to_stream.read
  end
end
