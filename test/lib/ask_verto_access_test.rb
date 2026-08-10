require "test_helper"

class AskVertoAccessTest < ActiveSupport::TestCase
  def setup
    @original_env = ENV["ASK_VERTO_USER_EMAILS"]
  end

  def teardown
    if @original_env.nil?
      ENV.delete("ASK_VERTO_USER_EMAILS")
    else
      ENV["ASK_VERTO_USER_EMAILS"] = @original_env
    end
  end

  test "allowed_emails parses + downcases the allowlist and is empty when unset" do
    ENV.delete("ASK_VERTO_USER_EMAILS")
    assert_empty AskVertoAccess.allowed_emails

    ENV["ASK_VERTO_USER_EMAILS"] = "  A@X.com ,B@Y.com\nc@z.com "
    assert_equal [ "a@x.com", "b@y.com", "c@z.com" ], AskVertoAccess.allowed_emails
  end

  test "unset list means open to everyone, signed in or not" do
    ENV.delete("ASK_VERTO_USER_EMAILS")
    assert AskVertoAccess.allowed?(User.new(email_address: "anyone@anywhere.com"))
    assert AskVertoAccess.allowed?(nil)
  end

  test "a set list matches case-insensitively and denies everyone else" do
    ENV["ASK_VERTO_USER_EMAILS"] = "nick@playverto.com"
    assert AskVertoAccess.allowed?(User.new(email_address: "NICK@playverto.com"))
    assert_not AskVertoAccess.allowed?(User.new(email_address: "partner@elsewhere.com"))
    assert_not AskVertoAccess.allowed?(nil)
  end
end
