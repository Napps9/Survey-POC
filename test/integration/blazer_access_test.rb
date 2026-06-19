require "test_helper"

# The Blazer BI engine is mounted behind a routing constraint, so non-staff
# requests never match the route at all. These cover the security boundary.
class BlazerAccessIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @original_env = ENV["BLAZER_STAFF_EMAILS"]
    @org   = Organisation.create!(name: "VertoNow", slug: "vertonow-#{SecureRandom.hex(2)}")
    @staff = make_user("staff@vertonow.com")
    @other = make_user("member@customer.com")
  end

  def teardown
    if @original_env.nil?
      ENV.delete("BLAZER_STAFF_EMAILS")
    else
      ENV["BLAZER_STAFF_EMAILS"] = @original_env
    end
  end

  def make_user(email)
    User.create!(name: "U", email_address: email, password: "verylongpassword").tap do |u|
      @org.memberships.create!(user: u, role: "member")
    end
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  # Either a 404 or a RoutingError is an acceptable "you can't get there".
  def assert_blazer_unreachable
    get "/blazer"
    assert_response :not_found
  rescue ActionController::RoutingError
    assert true
  end

  test "anonymous visitors cannot reach Blazer" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    assert_blazer_unreachable
  end

  test "a signed-in non-staff user cannot reach Blazer" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @other
    assert_blazer_unreachable
  end

  test "deny-by-default: staff is blocked while the allowlist is unset" do
    ENV.delete("BLAZER_STAFF_EMAILS")
    sign_in @staff
    assert_blazer_unreachable
  end

  test "a staff user on the allowlist reaches Blazer" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @staff
    get "/blazer"
    assert_includes 200..399, response.status
  end
end
