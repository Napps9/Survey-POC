require "test_helper"

# The ASK_VERTO_USER_EMAILS gate, walked through the real HTTP surface: the
# chat routes 404 for signed-in users off the list, and the nav entries that
# lead there (bottom bar chip, command palette tile) disappear for them.
# AskVertoAccessTest proves the predicate; this proves the wiring.
class AskVertoGateTest < ActionDispatch::IntegrationTest
  PASSWORD = "verylongpassword".freeze

  def setup
    @original_env = ENV["ASK_VERTO_USER_EMAILS"]

    @allowed = User.create!(name: "Owner", email_address: "avg-owner-#{SecureRandom.hex(3)}@test.com",
                            password: PASSWORD)
    @other   = User.create!(name: "Partner", email_address: "avg-other-#{SecureRandom.hex(3)}@test.com",
                            password: PASSWORD)
    @org = Organisation.create!(name: "Gate Test Org", slug: "avg-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @allowed, role: "admin")
    @org.memberships.create!(user: @other,   role: "admin")
  end

  def teardown
    if @original_env.nil?
      ENV.delete("ASK_VERTO_USER_EMAILS")
    else
      ENV["ASK_VERTO_USER_EMAILS"] = @original_env
    end
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: PASSWORD }
    follow_redirect! if response.redirect?
  end

  test "with the list unset the chat stays open to any signed-in account" do
    ENV.delete("ASK_VERTO_USER_EMAILS")
    sign_in @other

    get ask_path
    assert_response :success

    get root_path
    assert_match ask_path, response.body
  end

  test "a user off the list 404s on every chat route and loses the nav entries" do
    ENV["ASK_VERTO_USER_EMAILS"] = @allowed.email_address
    sign_in @other

    get ask_path
    assert_response :not_found

    post ask_threads_path, params: { title: "Blocked" }
    assert_response :not_found
    assert_equal 0, @org.ask_threads.count

    post ask_thread_messages_path(thread_id: 1), params: {}
    assert_response :not_found

    get root_path
    assert_response :success
    assert_no_match %r{href="#{ask_path}"}, response.body
  end

  test "a listed user keeps the chat and the nav entries" do
    ENV["ASK_VERTO_USER_EMAILS"] = @allowed.email_address.upcase
    sign_in @allowed

    get ask_path
    assert_response :success

    get root_path
    assert_match ask_path, response.body
  end
end
