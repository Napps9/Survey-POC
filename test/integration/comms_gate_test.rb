require "test_helper"

# The Playverto-membership gate on /comms, walked through the real HTTP
# surface: the routes 404 for everyone outside the Playverto org, and the
# nav entries that lead there (bottom bar chip, command palette tile)
# disappear for them. CommsAccessTest proves the predicate; this proves the
# wiring.
class CommsGateTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @playverto = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end
    @customer_org = Organisation.create!(name: "Customer", slug: "cg-#{SecureRandom.hex(3)}")

    @staff = User.create!(name: "Staff", email_address: "cg-staff-#{SecureRandom.hex(3)}@test.com",
                          password: PASSWORD)
    @playverto.memberships.create!(user: @staff, role: "member")

    @customer = User.create!(name: "Customer", email_address: "cg-cust-#{SecureRandom.hex(3)}@test.com",
                             password: PASSWORD)
    @customer_org.memberships.create!(user: @customer, role: "admin")
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  # Either a 404 or a RoutingError is an acceptable "you can't get there"
  # (the constraint means the route doesn't exist for the request).
  def assert_comms_unreachable
    get "/comms"
    assert_response :not_found
  rescue ActionController::RoutingError
    assert true
  end

  test "anonymous visitors cannot reach Comms" do
    assert_comms_unreachable
  end

  test "a signed-in user outside the Playverto org 404s and sees no nav entry" do
    sign_in @customer
    assert_comms_unreachable

    get root_path
    assert_response :success
    assert_no_match %r{href="/comms"}, response.body
  end

  test "a Playverto member reaches Comms and keeps the nav entry" do
    sign_in @staff

    get "/comms"
    assert_response :success

    get root_path
    assert_response :success
    assert_match %r{href="/comms"}, response.body
  end
end
