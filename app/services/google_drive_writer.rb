require "google/apis/drive_v3"
require "stringio"

# Uploads the report HTML to the user's Google Drive, asking Drive to convert it
# into a native Google Doc (mime_type application/vnd.google-apps.document).
# Returns the Doc's URL + id. Uses the same per-user OAuth credentials as the
# Sheets export — the drive.file scope already covers files the app creates.
class GoogleDriveWriter
  Result = Struct.new(:url, :id, keyword_init: true)

  Drive = Google::Apis::DriveV3

  def self.call(...) = new(...).call

  def initialize(user:, title:, html:)
    @user  = user
    @title = title
    @html  = html
  end

  def call
    service = Drive::DriveService.new
    service.client_options.application_name = "Playverto"
    service.authorization = GoogleOauthService.client_for(@user)

    file = service.create_file(
      Drive::File.new(name: @title, mime_type: "application/vnd.google-apps.document"),
      upload_source: StringIO.new(@html),
      content_type:  "text/html",
      fields:        "id, web_view_link"
    )

    Result.new(url: file.web_view_link, id: file.id)
  rescue Google::Apis::Error => e
    ErrorReporting.report("GoogleDriveWriter", e)
    raise
  end
end
