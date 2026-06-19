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
    assert_response :success
  end

  test "a staff user with no organisation can still reach Blazer" do
    # Real VertoNow staff generally aren't members of any customer org. Blazer
    # skips the app's organisation filter, so a membership must not be required.
    ENV["BLAZER_STAFF_EMAILS"] = "solo@vertonow.com"
    solo = User.create!(name: "Solo", email_address: "solo@vertonow.com", password: "verylongpassword")
    sign_in solo
    get "/blazer"
    assert_response :success
  end

  test "Blazer responses allow the 'unsafe-eval' its Vue UI needs; the rest of the app stays strict" do
    # Blazer's client-side Vue app evaluates its {{ }} templates via new Function(),
    # which the browser blocks without 'unsafe-eval' in script-src — leaving staff a
    # blank page. config/initializers/blazer.rb widens script-src for Blazer only.
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @staff

    get "/blazer"
    assert_response :success
    assert_includes response.headers["Content-Security-Policy"].to_s, "'unsafe-eval'",
                    "Blazer's Vue UI is blocked (blank page) without 'unsafe-eval' in its CSP"

    # Use an explicit app path: root_path is ambiguous here (the mounted Blazer
    # engine also defines one) and would resolve back to Blazer.
    get "/"
    assert_response :success
    assert_not_includes response.headers["Content-Security-Policy"].to_s, "'unsafe-eval'",
                        "the app-wide CSP must stay strict outside Blazer"
  end
end
