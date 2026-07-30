require "test_helper"

# P1-12. Login and password reset were bounded per IP only, so a rotating pool
# of addresses could grind through ONE account without ever tripping a limit —
# the IP counter never sees that shape.
#
# The larger find, not in the plan: two endpoints verified a password with NO
# rate limit at all. InvitesController#accept and
# FunderInviteAcceptancesController#accept both call User.authenticate_by with
# an email taken from the FORM rather than from the invite, which made each of
# them an unauthenticated password oracle against any address.
#
# Scope note, as in CacheStoreTest: Rails resolves `rate_limit`'s store once at
# class-definition time, and the suite runs on :null_store, so none of these
# limits can be driven end-to-end here. What's pinned is the declaration
# coverage — the thing that is actually missing when a new password path is
# added — and the keying, which is what makes the per-address limit work.
class AuthThrottlingTest < ActionDispatch::IntegrationTest
  # Every controller action in the app that verifies a password.
  PASSWORD_PATHS = {
    SessionsController                 => :create,
    InvitesController                  => :accept,
    FunderInviteAcceptancesController  => :accept
  }.freeze

  # Rails hides each rate limit inside an anonymous before_action lambda defined
  # in action_controller/metal/rate_limiting.rb, so counting callbacks whose
  # source_location is that file is the only way to see them.
  #
  # A first attempt at this matched "action_controller" broadly and reported
  # true for every controller inheriting ApplicationController — including ones
  # with no limit at all. Verified against LegalController and
  # OrganisationsController (0 each) before trusting it.
  RATE_LIMIT_SOURCE = "action_controller/metal/rate_limiting.rb".freeze

  def rate_limit_count(controller)
    controller._process_action_callbacks.count do |cb|
      cb.kind == :before && cb.filter.is_a?(Proc) &&
        cb.filter.source_location.to_a.first.to_s.end_with?(RATE_LIMIT_SOURCE)
    end
  end

  test "every password-verifying action is rate limited" do
    PASSWORD_PATHS.each do |controller, action|
      assert_operator rate_limit_count(controller), :>=, 1,
                      "#{controller}##{action} verifies a password and must be rate limited"
    end
  end

  test "the matcher would notice a controller with no limit" do
    # Guards the guard: without this, a matcher that returned true for
    # everything would make the assertions above meaningless — which is exactly
    # what the first version of it did.
    assert_equal 0, rate_limit_count(LegalController)
    assert_equal 0, rate_limit_count(OrganisationsController)
  end

  test "password reset is rate limited too" do
    assert_operator rate_limit_count(PasswordsController), :>=, 1
  end

  test "signing in declares both an IP and an address limit" do
    # Two limits, not one: the IP bound stops one machine trying many accounts,
    # the address bound stops many machines trying one account.
    assert_equal 2, rate_limit_count(SessionsController)
    source = File.read(Rails.root.join("app/controllers/sessions_controller.rb"))
    assert_match(/name: "ip"/, source)
    assert_match(/name: "email"/, source)
    assert_match(/params\[:email_address\]/, source)
  end

  test "password reset declares both limits" do
    assert_equal 2, rate_limit_count(PasswordsController)
    source = File.read(Rails.root.join("app/controllers/passwords_controller.rb"))
    assert_match(/name: "email"/, source)
  end

  test "the address key is normalised, so case can't multiply the budget" do
    # "Foo@Bar.com" and "foo@bar.com" must share one counter — otherwise the
    # limit is trivially bypassed by varying the case on each attempt.
    [ "app/controllers/sessions_controller.rb", "app/controllers/passwords_controller.rb" ].each do |path|
      source = File.read(Rails.root.join(path))
      assert_match(/params\[:email_address\]\.to_s\.strip\.downcase/, source,
                   "#{path} must normalise the address before keying on it")
    end
  end

  # ── The two endpoints that had nothing ──────────────────────────────────

  test "the invite accept endpoints declare a limit" do
    # Both had zero before this change.
    assert_equal 1, rate_limit_count(InvitesController)
    assert_equal 1, rate_limit_count(FunderInviteAcceptancesController)
  end

  test "an invite sign-in still works when under the limit" do
    # The limit must not break the flow it protects.
    org    = Organisation.create!(name: "O", slug: "at-#{SecureRandom.hex(3)}")
    admin  = User.create!(name: "A", email_address: "at-a-#{SecureRandom.hex(3)}@test.com",
                          password: "verylongpassword")
    org.memberships.create!(user: admin, role: "admin")
    invitee = User.create!(name: "I", email_address: "at-i-#{SecureRandom.hex(3)}@test.com",
                           password: "verylongpassword")
    invite = org.invites.create!(email_address: invitee.email_address, kind: "member",
                                 invited_by: admin, expires_at: 7.days.from_now)

    get invite_path(invite.token)
    assert_response :success
  end
end
