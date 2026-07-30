require "test_helper"

# P1-10 in the readiness plan claimed that "password-reset/invite/oauth lookups
# pass raw params, so Foo@Bar.com misses stored foo@bar.com". That is NOT true
# on this codebase: Rails' `normalizes` normalises values used in FINDER
# QUERIES as well as on write, so User.find_by / .where / .authenticate_by all
# match case-insensitively already, and every invite path downcases before it
# writes.
#
# These tests exist because that guarantee is invisible in the calling code —
# every one of those call sites reads like a raw lookup. Removing `normalizes`,
# or replacing it with a before_save, would silently break password resets,
# invite acceptance and Google sign-in with no failing test anywhere. So the
# behaviour is pinned here rather than left as a property of a gem version.
class EmailNormalizationTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: "N", email_address: "casey@example.com",
                         password: "verylongpassword")
  end

  test "a stored address is normalised on write" do
    user = User.create!(name: "N", email_address: "  MiXeD@Example.COM  ",
                        password: "verylongpassword")
    assert_equal "mixed@example.com", user.reload.email_address
  end

  test "find_by matches regardless of case or surrounding space" do
    # PasswordsController#create, InvitesController and OauthSessionsController
    # all pass user input straight to find_by.
    [ "casey@example.com", "Casey@Example.com", "CASEY@EXAMPLE.COM", "  casey@example.com  " ].each do |input|
      assert_equal @user.id, User.find_by(email_address: input)&.id,
                   "#{input.inspect} should find the stored address"
    end
  end

  test "where matches regardless of case" do
    assert_equal [ @user.id ], User.where(email_address: "CASEY@Example.com").pluck(:id)
  end

  test "authenticate_by matches regardless of case" do
    # The sign-in path, and the invite flow's "enter your existing password".
    assert_equal @user.id,
                 User.authenticate_by(email_address: "Casey@EXAMPLE.com",
                                      password: "verylongpassword")&.id
  end

  test "a password reset for a differently-cased address reaches the account" do
    # The end-to-end shape of the reported concern: someone types their address
    # with a capital and gets no email.
    found = User.find_by(email_address: "Casey@Example.Com")
    assert_equal @user.id, found&.id
    assert_nothing_raised { found.generate_token_for(:password_reset) }
  end

  test "uniqueness still catches a differently-cased duplicate" do
    dup = User.new(name: "N", email_address: "CASEY@example.com", password: "verylongpassword")
    assert_not dup.valid?
    assert_includes dup.errors[:email_address].join, "taken"
  end

  test "invite addresses are normalised on the model, not just by callers" do
    org    = Organisation.create!(name: "O", slug: "norm-#{SecureRandom.hex(3)}")
    invite = org.invites.create!(email_address: "  Invitee@Example.COM ", kind: "member",
                                 invited_by: @user, expires_at: 7.days.from_now)

    assert_equal "invitee@example.com", invite.reload.email_address
    assert_equal invite.id,
                 org.invites.pending.find_by(email_address: "INVITEE@example.com")&.id
  end

  test "a link invite's synthetic address is left usable" do
    # Funder/partnership link invites store link-<hex>@funder.invite and rely on
    # addressed_email returning nil for them; normalising must not disturb that.
    org    = Organisation.create!(name: "O", slug: "norm-#{SecureRandom.hex(3)}")
    invite = org.invites.create!(email_address: "link-#{SecureRandom.hex(8)}@funder.invite",
                                 kind: "member", invited_by: @user, expires_at: 7.days.from_now)

    assert_nil invite.addressed_email
  end
end
