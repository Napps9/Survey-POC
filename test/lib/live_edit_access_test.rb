require "test_helper"

# Who may edit a Verto the editing lock would otherwise freeze. An allowlist in
# LIVE_EDIT_USER_EMAILS with a DEFAULT — the owner asked for this for their own
# account by name, so it must work before anyone sets a variable on Render —
# that the environment replaces outright when set.
class LiveEditAccessTest < ActiveSupport::TestCase
  def setup
    @original_env = ENV["LIVE_EDIT_USER_EMAILS"]
  end

  def teardown
    if @original_env.nil?
      ENV.delete("LIVE_EDIT_USER_EMAILS")
    else
      ENV["LIVE_EDIT_USER_EMAILS"] = @original_env
    end
  end

  test "unset means the owner's address, and only that" do
    ENV.delete("LIVE_EDIT_USER_EMAILS")
    assert_equal [ "nick@playverto.com" ], LiveEditAccess.allowed_emails
    assert_equal LiveEditAccess::DEFAULT_EMAILS, "nick@playverto.com"
  end

  test "the environment replaces the default outright, parsed and downcased" do
    ENV["LIVE_EDIT_USER_EMAILS"] = "  A@X.com ,B@Y.com\nc@z.com "
    assert_equal [ "a@x.com", "b@y.com", "c@z.com" ], LiveEditAccess.allowed_emails
    assert_not_includes LiveEditAccess.allowed_emails, "nick@playverto.com",
                        "setting the list is how the default is narrowed, so it must not linger"
  end

  test "a blank value switches the override off for everyone" do
    ENV["LIVE_EDIT_USER_EMAILS"] = ""
    assert_empty LiveEditAccess.allowed_emails
    assert_not LiveEditAccess.allowed?(verified("nick@playverto.com"))
  end

  test "allowed? matches case-insensitively and denies everyone else, nil included" do
    ENV.delete("LIVE_EDIT_USER_EMAILS")
    assert LiveEditAccess.allowed?(verified("NICK@playverto.com"))
    assert_not LiveEditAccess.allowed?(verified("partner@elsewhere.com"))
    assert_not LiveEditAccess.allowed?(verified(""))
    assert_not LiveEditAccess.allowed?(nil)
  end

  # Sign-up is open, so on a database without the owner's row the default
  # address could be registered by anyone — the mailbox has to be proven first.
  test "the address alone is not enough: it has to be verified" do
    ENV.delete("LIVE_EDIT_USER_EMAILS")
    assert_not LiveEditAccess.allowed?(User.new(email_address: "nick@playverto.com"))
    assert LiveEditAccess.allowed?(verified("nick@playverto.com"))
  end

  private

  def verified(email)
    User.new(email_address: email, email_verified_at: Time.current)
  end
end
