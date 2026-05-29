require "google/apis/sheets_v4"

# Creates a new spreadsheet in the user's Google Drive with two tabs
# ("Responses" and "Summary") and fills them with the given rows. Returns the
# spreadsheet's URL + id.
class GoogleSheetsWriter
  Result = Struct.new(:url, :id, keyword_init: true)

  Sheets = Google::Apis::SheetsV4

  def self.call(...) = new(...).call

  def initialize(user:, title:, response_rows:, summary_rows:)
    @user          = user
    @title         = title
    @response_rows = response_rows
    @summary_rows  = summary_rows
  end

  def call
    service = Sheets::SheetsService.new
    service.client_options.application_name = "Playverto"
    service.authorization = GoogleOauthService.client_for(@user)

    spreadsheet = service.create_spreadsheet(
      Sheets::Spreadsheet.new(
        properties: Sheets::SpreadsheetProperties.new(title: @title),
        sheets: [
          Sheets::Sheet.new(properties: Sheets::SheetProperties.new(title: "Responses")),
          Sheets::Sheet.new(properties: Sheets::SheetProperties.new(title: "Summary"))
        ]
      )
    )

    service.batch_update_values(
      spreadsheet.spreadsheet_id,
      Sheets::BatchUpdateValuesRequest.new(
        value_input_option: "RAW",
        data: [
          Sheets::ValueRange.new(range: "Responses!A1", values: @response_rows),
          Sheets::ValueRange.new(range: "Summary!A1",   values: @summary_rows)
        ]
      )
    )

    Result.new(url: spreadsheet.spreadsheet_url, id: spreadsheet.spreadsheet_id)
  rescue Google::Apis::Error => e
    Rails.logger.error("[GoogleSheetsWriter] #{e.class}: #{e.message}")
    raise
  end
end
