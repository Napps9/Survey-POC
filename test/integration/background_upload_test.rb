require "test_helper"

# Uploaded Verto backgrounds (sent as base64 by the editor autosave PATCH) are
# offloaded to Active Storage and the row stores the blob URL — not the bytes.
class BackgroundUploadTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "bg-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "bg-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: [])
  end

  def patch_bg(value)
    patch survey_path(@survey), params: { background_image: value }.to_json,
          headers: { "Content-Type" => "application/json" }
  end

  def png_data_url
    "data:image/png;base64,#{Base64.strict_encode64("\x89PNG\r\n\x1a\n" + ("x" * 64))}"
  end

  test "a base64 background is offloaded to a blob and the row stores the URL" do
    patch_bg(png_data_url)
    assert_response :success
    @survey.reload
    assert @survey.background_file.attached?, "background should be attached to object storage"
    assert_match %r{\A/rails/active_storage/}, @survey.background_image, "row stores the blob URL, not base64"
    refute_match(/\Adata:/, @survey.background_image, "row must not keep the base64 data URL")
  end

  test "clearing the background purges the blob" do
    patch_bg(png_data_url)
    @survey.reload
    assert @survey.background_file.attached?

    patch_bg("")
    assert_response :success
    @survey.reload
    assert_nil @survey.background_image
  end

  test "a library asset path is stored verbatim (no blob)" do
    patch_bg("/assets/verto-library/backgrounds/landscape.jpg")
    assert_response :success
    @survey.reload
    assert_equal "/assets/verto-library/backgrounds/landscape.jpg", @survey.background_image
    refute @survey.background_file.attached?
  end
end
