require "test_helper"

# The logo upload had no integration coverage at all, which is how it shipped
# answering some failures with a bare 400 and an empty body. The defect users
# reported was an *unreadable* response rather than a wrong one, so what these
# pin is the contract the client depends on: a JSON request always comes back
# as parseable JSON carrying a human-readable reason.
class OrganisationLogoTest < ActionDispatch::IntegrationTest
  def setup
    @org    = Organisation.create!(name: "Brand", slug: "brand-#{SecureRandom.hex(2)}")
    @admin  = User.create!(name: "Adm", email_address: "logo-adm-#{SecureRandom.hex(2)}@test.com",
                           password: "verylongpassword")
    @member = User.create!(name: "Mem", email_address: "logo-mem-#{SecureRandom.hex(2)}@test.com",
                           password: "verylongpassword")
    @org.memberships.create!(user: @admin,  role: "admin")
    @org.memberships.create!(user: @member, role: "member")
    login(@admin)
  end

  def login(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def png(name = "logo.png", bytes: "\x89PNG\r\n\x1a\n", type: "image/png")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: name)
  end

  def patch_logo(params)
    patch organisation_path(@org), params: params, headers: { "Accept" => "application/json" }
  end

  # Every failure path below asserts this, because a body the client can read is
  # the whole point of the change.
  def assert_readable_json_error
    assert_equal "application/json", response.media_type,
                 "a JSON request must never be answered with HTML"
    body = JSON.parse(response.body)
    refute body["ok"]
    assert body["error"].present?, "a rejection must say why"
    body
  end

  test "an admin uploads a logo and gets its URL back" do
    patch_logo(organisation: { logo: png })

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert body["logo_url"].present?
    assert @org.reload.logo.attached?
  end

  test "an admin removes the logo" do
    @org.logo.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "l.png", content_type: "image/png")

    patch_logo(organisation: { remove_logo: "1" })

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_nil body["logo_url"]
    refute @org.reload.logo.attached?
  end

  test "an oversized logo is refused with a reason, not a bare status" do
    patch_logo(organisation: { logo: png("big.png", bytes: "a" * (Organisation::LOGO_MAX_BYTES + 1)) })

    assert_response :unprocessable_entity
    assert_match(/2 MB/, assert_readable_json_error["error"])
    refute @org.reload.logo.attached?
  end

  test "an unsupported content type is refused with a reason" do
    patch_logo(organisation: { logo: png("evil.txt", bytes: "not an image", type: "text/plain") })

    assert_response :unprocessable_entity
    assert_match(/PNG|image/i, assert_readable_json_error["error"])
    refute @org.reload.logo.attached?
  end

  # The specific regression: params.require(:organisation) raised
  # ActionController::ParameterMissing, which Rails answers with a bare 400 and
  # an empty body — exactly what an interrupted multipart upload produces.
  test "a request missing the organisation key is a readable 422, never a bare 400" do
    patch organisation_path(@org), params: {}, headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity, "a malformed request must not surface as a bare 400"
    assert_readable_json_error
  end

  test "a non-admin asking for JSON is refused in JSON, not redirected to HTML" do
    login(@member)

    patch_logo(organisation: { logo: png })

    assert_response :forbidden
    assert_readable_json_error
    refute @org.reload.logo.attached?
  end

  test "the HTML form path still redirects with a flash" do
    patch organisation_path(@org), params: { organisation: { logo: png } }

    assert_redirected_to organisation_memberships_path(@org)
    assert_equal "Brand updated.", flash[:notice]
  end
end
