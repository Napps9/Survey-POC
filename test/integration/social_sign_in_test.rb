require "test_helper"

class SocialSignInTest < ActionDispatch::IntegrationTest
  # The OmniAuth middleware only mounts strategies whose env vars existed at
  # boot, so tests inject the auth hash directly into the Rack env that every
  # request in this process sees — the controller reads request.env.
  def with_auth_hash(provider:, uid:, email:, name:, verified: true)
    Rails.application.env_config["omniauth.auth"] = OmniAuth::AuthHash.new(
      provider: provider, uid: uid,
      info:  { email: email, name: name },
      extra: { raw_info: { email_verified: verified } }
    )
    yield
  ensure
    Rails.application.env_config.delete("omniauth.auth")
  end

  test "first social sign-in creates a user, workspace org and identity" do
    with_auth_hash(provider: "google_oauth2", uid: "g-123", email: "Nina@Example.com", name: "Nina Park") do
      assert_difference [ "User.count", "Organisation.count", "Identity.count" ], 1 do
        get oauth_callback_path(provider: "google_oauth2")
      end
    end
    assert_redirected_to root_path

    user = User.order(:id).last
    assert_equal [ "Nina Park", "nina@example.com" ], [ user.name, user.email_address ]
    assert_equal "Nina's workspace", user.organisations.first.name
    assert_equal "admin", user.memberships.first.role
    assert_equal [ "google_oauth2", "g-123" ], [ user.identities.first.provider, user.identities.first.uid ]

    follow_redirect!
    assert_response :success, "should be signed in and land on the dashboard"
  end

  test "returning identity signs in without creating anything" do
    user = User.create!(name: "Ret", email_address: "ret-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-ret-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    user.identities.create!(provider: "entra_id", uid: "ms-9")

    with_auth_hash(provider: "entra_id", uid: "ms-9", email: user.email_address, name: "Ret") do
      assert_no_difference [ "User.count", "Identity.count", "Organisation.count" ] do
        get oauth_callback_path(provider: "entra_id")
      end
    end
    assert_redirected_to root_path
    assert_equal user.id, Session.order(:id).last.user_id
  end

  test "matching email links a new provider to the existing account" do
    user = User.create!(name: "Link", email_address: "link-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-link-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")

    with_auth_hash(provider: "apple", uid: "ap-7", email: user.email_address.upcase, name: nil) do
      assert_no_difference "User.count" do
        assert_difference "Identity.count", 1 do
          get oauth_callback_path(provider: "apple")
        end
      end
    end
    assert_equal user.id, Identity.find_by(provider: "apple", uid: "ap-7").user_id
  end

  test "missing email is rejected with a clear message" do
    with_auth_hash(provider: "apple", uid: "ap-noemail", email: nil, name: "Anon") do
      assert_no_difference "User.count" do
        get oauth_callback_path(provider: "apple")
      end
    end
    assert_redirected_to new_session_path
    assert_match "Apple", flash[:alert]
  end

  test "auth failure redirects to sign-in with an alert" do
    get "/auth/failure", params: { strategy: "google_oauth2" }
    assert_redirected_to new_session_path
    assert_match "Google", flash[:alert]
  end

  test "social buttons render only for configured providers" do
    get new_session_path
    assert_response :success
    refute_match "auth/google_oauth2", response.body, "no buttons without credentials"

    ENV["MICROSOFT_CLIENT_ID"]     = "test-id"
    ENV["MICROSOFT_CLIENT_SECRET"] = "test-secret"
    begin
      get new_registration_path
      assert_response :success
      assert_match "auth/entra_id", response.body
      assert_match "Microsoft", response.body
      refute_match "auth/apple", response.body
    ensure
      ENV.delete("MICROSOFT_CLIENT_ID")
      ENV.delete("MICROSOFT_CLIENT_SECRET")
    end
  end
end
