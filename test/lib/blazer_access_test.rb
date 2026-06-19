require "test_helper"

class BlazerAccessTest < ActiveSupport::TestCase
  def setup
    @original_env = ENV["BLAZER_STAFF_EMAILS"]
  end

  def teardown
    if @original_env.nil?
      ENV.delete("BLAZER_STAFF_EMAILS")
    else
      ENV["BLAZER_STAFF_EMAILS"] = @original_env
    end
  end

  # Minimal stand-in for ActionDispatch::Request#cookie_jar.signed[:session_id].
  def request_with_session(session_id)
    signed = session_id ? { session_id: session_id } : {}
    jar = Struct.new(:signed).new(signed)
    Struct.new(:cookie_jar).new(jar)
  end

  test "staff_emails parses + downcases the allowlist and is deny-all when unset" do
    ENV.delete("BLAZER_STAFF_EMAILS")
    assert_empty BlazerAccess.staff_emails

    ENV["BLAZER_STAFF_EMAILS"] = "  A@X.com ,B@Y.com\nc@z.com "
    assert_equal [ "a@x.com", "b@y.com", "c@z.com" ], BlazerAccess.staff_emails
  end

  test "staff? matches the allowlist case-insensitively and denies everyone else" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    assert BlazerAccess.staff?(User.new(email_address: "STAFF@vertonow.com"))
    assert_not BlazerAccess.staff?(User.new(email_address: "rando@elsewhere.com"))
    assert_not BlazerAccess.staff?(nil)
  end

  test "user_for resolves the signed-in user from the session cookie" do
    org  = Organisation.create!(name: "VertoNow", slug: "vertonow-#{SecureRandom.hex(2)}")
    user = User.create!(name: "Staff", email_address: "staff@vertonow.com", password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    session = user.sessions.create!(user_agent: "test", ip_address: "127.0.0.1")

    assert_equal user, BlazerAccess.user_for(request_with_session(session.id))
  end

  test "staff_request? gates on both a valid session and the allowlist" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    org   = Organisation.create!(name: "VertoNow", slug: "vertonow-#{SecureRandom.hex(2)}")
    staff = User.create!(name: "Staff", email_address: "staff@vertonow.com", password: "verylongpassword")
    other = User.create!(name: "Other", email_address: "member@customer.com", password: "verylongpassword")
    org.memberships.create!(user: staff, role: "admin")
    org.memberships.create!(user: other, role: "member")

    assert BlazerAccess.staff_request?(request_with_session(staff.sessions.create!.id))
    assert_not BlazerAccess.staff_request?(request_with_session(other.sessions.create!.id))
    assert_not BlazerAccess.staff_request?(request_with_session(nil))
    assert_not BlazerAccess.staff_request?(request_with_session(-1))
  end
end
