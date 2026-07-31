require "test_helper"

# P1-6, repo half. The encryption keys are Render-generated with
# `generateValue: true`, which mints them once for a service and never backs
# them up — so a recreated service means every stored Google token is encrypted
# with a key that no longer exists.
#
# The backup itself is an ops task (docs/ENCRYPTION_KEYS.md). What is testable
# here is the blast radius, which used to be much larger than the plan implied:
# `google_connected?` is called from the dashboard view, so an undecryptable
# token 500'd the app's home page for the affected user — including the page
# they would have used to reconnect.
#
# A real key change can only be simulated across processes (the key provider is
# memoized), so this stubs the decryption failure at the point it surfaces,
# which is what the guards actually handle.
class GoogleTokenDecryptionTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: "G", email_address: "g-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.update!(google_refresh_token: "a-refresh-token")
  end

  def with_undecryptable_token
    stub_method(@user, :google_refresh_token,
                -> { raise ActiveRecord::Encryption::Errors::Decryption, "key mismatch" }) do
      yield
    end
  end

  test "an undecryptable token reads as not connected rather than raising" do
    with_undecryptable_token do
      assert_nothing_raised do
        refute @user.google_connected?,
               "the dashboard calls this — it must not raise when the keys have changed"
      end
    end
  end

  test "the readable-token accessor returns nil rather than raising" do
    with_undecryptable_token do
      assert_nil @user.google_refresh_token_if_readable
    end
  end

  test "a decryption failure is reported, not swallowed" do
    # Degrading quietly would hide the one condition that needs a human: the
    # keys no longer match the data, and only a restore fixes that.
    reported = []
    stub_method(ErrorReporting, :report, ->(tag, error, **) { reported << [ tag, error.class ] }) do
      with_undecryptable_token { @user.google_connected? }
    end

    assert_equal 1, reported.size
    assert_equal "User#google_token", reported.first.first
  end

  # The negative cases: none of the above may change behaviour when the keys are
  # fine, or every healthy install would report itself broken.
  test "a healthy token still reads as connected" do
    reported = []
    stub_method(ErrorReporting, :report, ->(*_a, **_k) { reported << true }) do
      assert @user.google_connected?
      assert_equal "a-refresh-token", @user.google_refresh_token_if_readable
    end
    assert_empty reported
  end

  test "a user who never connected is simply not connected" do
    other = User.create!(name: "N", email_address: "n-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    refute other.google_connected?
    assert_nil other.google_refresh_token_if_readable
  end

  # Only the decryption error is caught. Anything else must still surface.
  test "an unrelated error is not swallowed" do
    stub_method(@user, :google_refresh_token, -> { raise ArgumentError, "something else" }) do
      assert_raises(ArgumentError) { @user.google_connected? }
    end
  end

  test "the export service treats an unreadable token as not connected" do
    with_undecryptable_token do
      assert_raises(GoogleOauthService::NotConnected) do
        GoogleOauthService.client_for(@user)
      end
    end
  end
end
