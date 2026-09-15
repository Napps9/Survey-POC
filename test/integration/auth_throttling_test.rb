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

  # Endpoints that verify no password but ISSUE a credential — a respondent
  # sign-in link, and the page that spends one. Same exposure for a different
  # reason: PlayerController#join mints an account and a sign-in link from
  # nothing but an address typed into a form, so an uncapped one lets a machine
  # walk a list into rows nobody asked for, and PlayerSignInsController#create
  # spends a bearer token whose only bound is that it was issued somewhere.
  #
  # This comment used to say #join "sends mail to an address a stranger typed",
  # and the caps in PlayerController were sized as a mail-bomb guard on that
  # basis. It doesn't send mail — PlayerSignInLink.mint! delivers nothing — and
  # the caps are sized for account creation now. The endpoints still belong
  # here; only the reason changed.
  CREDENTIAL_ISSUING_PATHS = {
    PlayerController      => :join,
    PlayerSignInsController => :create
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

  test "every credential-issuing action is rate limited" do
    CREDENTIAL_ISSUING_PATHS.each do |controller, action|
      assert_operator rate_limit_count(controller), :>=, 1,
                      "#{controller}##{action} issues a credential and must be rate limited"
    end
  end

  test "join declares both an IP and an address limit, normalised" do
    # Two limits for the same reason signing in has two: the IP bound stops one
    # machine walking a list of addresses, the address bound stops a rotating
    # pool of IPs mailing ONE inbox over and over.
    source = File.read(Rails.root.join("app/controllers/player_controller.rb"))
    assert_match(/name: "join_ip"/, source)
    assert_match(/name: "join_email"/, source)
    assert_match(/params\[:email\]\.to_s\.strip\.downcase/, source,
                 "the join address key must be normalised, or case multiplies the budget")
  end

  test "join's refusal is the success shape" do
    # An endpoint that answers 429 tells a caller which addresses it has
    # already spent — see PlayerController#join. Both limits must render the
    # ordinary body.
    lines = File.readlines(Rails.root.join("app/controllers/player_controller.rb"))
    declarations = lines.each_index.select { |i| lines[i].include?("only: :join,") }
    assert_equal 2, declarations.size, "join should still declare exactly two limits"

    declarations.each do |i|
      block = lines[i, 3].join
      refute_match(/too_many_requests/, block,
                   "a 429 here would tell a caller which addresses it had already spent")
      assert_match(/render json: \{ ok: true \}/, block)
    end
  end

  test "the join scale leaves every number unchanged at its default" do
    # PLAYER_JOIN_RATE_LIMIT_SCALE is unset in test, which is the promise the
    # comment above the declarations makes: setting nothing changes nothing.
    # Pinned as numbers rather than as source, because this is the half that a
    # typo in the multiplication would silently get wrong.
    assert_equal 1, PlayerController::JOIN_RATE_LIMIT_SCALE
    assert_equal 30, PlayerController::MAX_JOIN_ADDRESSES_PER_IP
    assert_equal 5, PlayerController::MAX_JOIN_PER_ADDRESS
  end

  test "the join scale reaches the per-IP gates and only those" do
    source = File.read(Rails.root.join("app/controllers/player_controller.rb"))

    ip_gates = source.lines.select { |l| l.match?(/name: "join_ip"|name: "join_google_ip"/) }
    assert_equal 2, ip_gates.size, "expected exactly the two per-IP join gates"
    ip_gates.each do |line|
      assert_match(/\* JOIN_RATE_LIMIT_SCALE/, line,
                   "a per-IP join gate must carry the scale or a venue crowd hits it: #{line.strip}")
    end

    address_gate = source.lines.find { |l| l.include?('name: "join_email"') }
    refute_match(/JOIN_RATE_LIMIT_SCALE/, address_gate,
                 "the address-keyed limit must NOT scale — a bigger crowd is not a reason " \
                 "to let one account be ground at harder")
    assert_match(/^  MAX_JOIN_PER_ADDRESS\s+= 5$/, source,
                 "MAX_JOIN_PER_ADDRESS is per-address and must stay flat for the same reason")
  end

  test "the join scale cannot switch the cap off" do
    # 0 and a fat-fingered value both .to_i to 0, and a scale of 0 is not
    # "unlimited" — it multiplies every cap to zero, so `to: 0` refuses
    # everyone and MAX_JOIN_ADDRESSES_PER_IP of 0 refuses every address. The
    # clamp is the whole reason an unset or mistyped value is safe rather than
    # a total outage of signup.
    source = File.read(Rails.root.join("app/controllers/player_controller.rb"))
    assert_match(/JOIN_RATE_LIMIT_SCALE = ENV\.fetch\("PLAYER_JOIN_RATE_LIMIT_SCALE", "1"\)\.to_i\.clamp\(1, 10_000\)/,
                 source)
  end

  test "the join scale reaches the whole join journey, not just PlayerController" do
    # #join does not finish a signup. It mints a PlayerSignInLink and returns
    # its path; the player navigates to PlayerSignInsController#create, and that
    # is where the account begins. Scaling only the first half meant a crowd
    # cleared a 250-per-5-minutes gate and hit a 20-per-5-minutes one seconds
    # later — so the property worth pinning is that BOTH controllers read the
    # SAME environment variable, not that either holds a particular number.
    assert_equal PlayerController::JOIN_RATE_LIMIT_SCALE,
                 PlayerSignInsController::JOIN_RATE_LIMIT_SCALE,
                 "both halves of the join journey must scale together"

    signin = File.read(Rails.root.join("app/controllers/player_sign_ins_controller.rb"))
    assert_match(/ENV\.fetch\("PLAYER_JOIN_RATE_LIMIT_SCALE", "1"\)\.to_i\.clamp\(1, 10_000\)/, signin,
                 "the sign-in half must read the same lever, with the same clamp")
    decl = signin.lines.find { |l| l.include?('name: "signin_ip"') }
    assert_match(/\* JOIN_RATE_LIMIT_SCALE/, decl,
                 "signin_ip is the cap a joining crowd actually hits — it must carry the scale")
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
