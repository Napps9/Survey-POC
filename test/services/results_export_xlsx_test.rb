require "test_helper"

class ResultsExportXlsxTest < ActiveSupport::TestCase
  AGG = Class.new do
    include AggregatesSurveyResults
    def build(cards, responses) = aggregate_results(cards, responses)
  end.new

  def setup
    @org = Organisation.create!(name: "T", slug: "rxl-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome" },
        { "type" => "multiple_choice", "text" => "Favourite colour?", "options" => %w[Blue Green] },
        { "type" => "open_ended", "text" => "Anything else?" }
      ]
    )
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answers: {
      "1" => { "type" => "multiple_choice", "value" => "Blue" },
      "2" => { "type" => "open_ended", "value" => "=HYPERLINK(\"http://evil.example\",\"click me\")" }
    })
    responses  = @survey.responses.where(status: "completed").order(:created_at)
    aggregated = AGG.build(Array(@survey.cards), responses)
    @export    = ResultsExport.new(survey: @survey, responses: responses, aggregated: aggregated)
  end

  def teardown
    @survey.destroy
    @org.destroy
  end

  # A workbook of one worksheet is always xl/worksheets/sheet1.xml — each
  # ResultsExportXlsx instance builds its own single-sheet package. Axlsx
  # writes plain string cells as inline strings (t="inlineStr", <is><t>…</t>
  # </is>), not a shared-strings table, so that's what's asserted against.
  #
  # Zip::File.open_buffer returns the buffer it was given, NOT the block's
  # value, so the content has to be captured into an outer local rather than
  # returned from the block.
  def sheet1_xml(bytes)
    xml = nil
    Zip::File.open_buffer(StringIO.new(bytes)) { |zip| xml = zip.find_entry("xl/worksheets/sheet1.xml")&.get_input_stream&.read }
    xml
  end

  test "the returned bytes are a real xlsx (zip) container" do
    bytes = ResultsExportXlsx.new(@export, summary: false).to_stream
    assert_kind_of String, bytes
    assert bytes.start_with?("PK"), "expected a zip container"
  end

  test "the responses workbook carries the question text and the answer" do
    xml = sheet1_xml(ResultsExportXlsx.new(@export, summary: false).to_stream)
    assert_includes xml, "<t>Favourite colour?</t>"
    assert_includes xml, "<t>Blue</t>"
  end

  test "the summary workbook carries the question and an option count" do
    xml = sheet1_xml(ResultsExportXlsx.new(@export, summary: true).to_stream)
    assert_includes xml, "<t>Favourite colour?</t>"
    assert_includes xml, "<t>Blue</t>"
  end

  test "a hostile leading-formula answer survives as inline text, never a formula" do
    xml = sheet1_xml(ResultsExportXlsx.new(@export, summary: false).to_stream)

    # ResultsExport#csv_safe already prefixed the value with a leading
    # apostrophe before it ever reached this service — the XML entity-encodes
    # it, but the visible text is unchanged from what the CSV export shows.
    assert_includes xml, "&#39;=HYPERLINK"
    assert_no_match(/<f>/, xml, "the hostile cell must never carry a formula element")
    # An explicit :string cell is inlineStr, not left to numeric/general
    # inference — that's what makes the leading "=" inert in Excel.
    assert_match(%r{t="inlineStr"[^>]*><is><t>&#39;=HYPERLINK}, xml)
  end

  test "numeric summary cells stay real numbers, not text" do
    xml = sheet1_xml(ResultsExportXlsx.new(@export, summary: true).to_stream)
    # The "Blue" count is 1 — a plain numeric cell (t="n"), sortable/summable
    # in Excel, not the inlineStr type used for every text cell.
    assert_match(%r{<c r="[A-Z]+\d+" s="\d+" t="n"><v>1</v></c>}, xml)
  end
end
