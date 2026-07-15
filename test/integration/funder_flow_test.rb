require "test_helper"

class FunderFlowTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "A", email_address: "creator@test.com", password: "verylongpassword")
    @oa = Organisation.create!(name: "Creator Co", slug: "creator-co-#{SecureRandom.hex(2)}")
    @oa.memberships.create!(user: @admin, role: "admin")
    sign_in @admin
  end

  test "creator creates a funder, invites and adds a licensed org" do
    get funders_path
    assert_response :success
    assert_match "No funders yet", response.body

    get new_funder_path
    assert_response :success
    assert_match "Funder name", response.body

    post funders_path, params: { funder: { name: "Northside Foundation", seat_count: 2 } }
    assert_redirected_to funder_path(Funder.last)
    follow_redirect!
    assert_response :success
    assert_match "Northside Foundation", response.body
    assert_match "No organisations licensed yet", response.body

    fu = Funder.last

    post funder_funder_invites_path(fu)
    assert_redirected_to funder_path(fu, new_invite_token: Invite.last.token)
    follow_redirect!
    assert_match "New join link", response.body

    licensed_email = "b-#{SecureRandom.hex(2)}@test.com"
    invite_token = Invite.last.token
    delete session_path
    post accept_funder_invite_path(invite_token), params: {
      name: "Org B Admin",
      organisation_name: "Org B",
      email_address: licensed_email,
      password: "verylongpassword",
      password_confirmation: "verylongpassword"
    }
    assert_redirected_to funder_path(fu)
    follow_redirect!
    assert_match "Northside Foundation", response.body
    assert_match "Run by Creator Co", response.body

    assert fu.funder_memberships.active.exists?(organisation: Organisation.find_by(name: "Org B"))

    delete session_path
    sign_in @admin
    get funder_path(fu)
    assert_match "Org B", response.body
    assert_match(/1\s*<\/span>/, response.body.gsub(/\s+/, " ")) # sanity: page renders without error
  end

  test "seat limit blocks generating another invite once full" do
    fu = @oa.funders.create!(name: "Small Fund", seat_count: 1)
    other_org = Organisation.create!(name: "Filled Org", slug: "filled-#{SecureRandom.hex(2)}")
    FunderMembership.assign!(funder: fu, organisation: other_org)

    post funder_funder_invites_path(fu)
    assert_redirected_to funder_path(fu)
    follow_redirect!
    assert_match "No seats available", response.body
    assert_equal 0, fu.invites.count
  end

  test "seat limit blocks creating an account directly once full" do
    fu = @oa.funders.create!(name: "Small Fund", seat_count: 1)
    other_org = Organisation.create!(name: "Filled Org", slug: "filled-#{SecureRandom.hex(2)}")
    FunderMembership.assign!(funder: fu, organisation: other_org)

    assert_no_difference "User.count" do
      post funder_funder_accounts_path(fu), params: {
        name: "Jamie", email_address: "jamie-#{SecureRandom.hex(2)}@licensed.org",
        organisation_name: "New Org"
      }
    end
    assert_response :unprocessable_entity
    assert_match "No seats available", response.body
  end

  test "suspending a licensed org frees its seat for reassignment" do
    fu = @oa.funders.create!(name: "Small Fund", seat_count: 1)
    org_a = Organisation.create!(name: "Org A", slug: "org-a-#{SecureRandom.hex(2)}")
    membership = FunderMembership.assign!(funder: fu, organisation: org_a)

    assert_equal 0, fu.seats_available

    patch funder_funder_membership_path(fu, membership), params: { status: "suspended" }
    assert_redirected_to funder_path(fu)
    assert membership.reload.suspended?
    assert_equal 1, fu.seats_available

    org_b = Organisation.create!(name: "Org B", slug: "org-b-#{SecureRandom.hex(2)}")
    FunderMembership.assign!(funder: fu, organisation: org_b)
    assert_equal 0, fu.seats_available
  end

  test "reactivating a suspended membership fails once seats are full again" do
    fu = @oa.funders.create!(name: "Small Fund", seat_count: 1)
    org_a = Organisation.create!(name: "Org A", slug: "org-a2-#{SecureRandom.hex(2)}")
    membership_a = FunderMembership.assign!(funder: fu, organisation: org_a)
    membership_a.suspend!

    org_b = Organisation.create!(name: "Org B", slug: "org-b2-#{SecureRandom.hex(2)}")
    FunderMembership.assign!(funder: fu, organisation: org_b)

    patch funder_funder_membership_path(fu, membership_a), params: { status: "active" }
    assert_redirected_to funder_path(fu)
    follow_redirect!
    assert_match "No seats available", response.body
    refute membership_a.reload.active?
  end

  test "admin can raise the seat count from the dashboard" do
    fu = @oa.funders.create!(name: "Growing Fund", seat_count: 1)

    patch funder_path(fu), params: { funder: { seat_count: 5 } }
    assert_redirected_to funder_path(fu)
    assert_equal 5, fu.reload.seat_count
  end

  test "signed-in admin of an existing org joins a funder via the join link" do
    licensed_admin = User.create!(name: "Existing", email_address: "exist-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    licensed_org = Organisation.create!(name: "Existing Co", slug: "exist-#{SecureRandom.hex(2)}")
    licensed_org.memberships.create!(user: licensed_admin, role: "admin")

    fu = @oa.funders.create!(name: "Existing-User Fund", seat_count: 3)
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@funder.invite",
      role: "admin", kind: "licensee",
      funder: fu, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    delete session_path
    sign_in licensed_admin

    get funder_invite_path(invite.token)
    assert_response :success
    assert_match "Signed in as", response.body
    assert_match "Join with", response.body
    assert_match "Existing Co", response.body

    post accept_funder_invite_path(invite.token), params: { join_as_organisation_id: licensed_org.id }
    assert_redirected_to funder_path(fu)
    follow_redirect!
    assert_match "Existing-User Fund", response.body

    assert fu.funder_memberships.exists?(organisation: licensed_org)
    assert invite.reload.accepted?
  end

  test "signed-in user with multiple admin orgs picks which one joins" do
    user = User.create!(name: "Multi", email_address: "multi-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org_x = Organisation.create!(name: "Org X", slug: "ox-#{SecureRandom.hex(2)}")
    org_y = Organisation.create!(name: "Org Y", slug: "oy-#{SecureRandom.hex(2)}")
    org_x.memberships.create!(user: user, role: "admin")
    org_y.memberships.create!(user: user, role: "admin")

    fu = @oa.funders.create!(name: "Multi-Org Fund", seat_count: 3)
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@funder.invite",
      role: "admin", kind: "licensee",
      funder: fu, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    delete session_path
    sign_in user

    get funder_invite_path(invite.token)
    assert_response :success
    assert_match "Pick which organisation joins", response.body

    post accept_funder_invite_path(invite.token), params: { join_as_organisation_id: org_y.id }
    assert_redirected_to funder_path(fu)

    assert fu.funder_memberships.exists?(organisation: org_y)
    refute fu.funder_memberships.exists?(organisation: org_x)
  end

  test "signed-in admin of the funder creator cannot join their own funder" do
    fu = @oa.funders.create!(name: "Self-Join Test", seat_count: 3)
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@funder.invite",
      role: "admin", kind: "licensee",
      funder: fu, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    get funder_invite_path(invite.token)
    assert_response :success
    assert_match "You run this funder", response.body
    refute_match "Pick which organisation joins", response.body
  end

  test "existing not-signed-in user can sign in via the funder invite page" do
    licensed_admin = User.create!(name: "Returning", email_address: "ret-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    licensed_org = Organisation.create!(name: "Returning Co", slug: "ret-#{SecureRandom.hex(2)}")
    licensed_org.memberships.create!(user: licensed_admin, role: "admin")

    fu = @oa.funders.create!(name: "Sign-In Test Fund", seat_count: 3)
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@funder.invite",
      role: "admin", kind: "licensee",
      funder: fu, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    delete session_path

    get funder_invite_path(invite.token)
    assert_response :success
    assert_match "Sign in instead", response.body

    post accept_funder_invite_path(invite.token), params: {
      mode: "sign_in",
      email_address: licensed_admin.email_address,
      password: "verylongpassword"
    }
    assert_redirected_to funder_invite_path(invite.token)
    follow_redirect!
    assert_match "Signed in as", response.body

    refute invite.reload.accepted?

    post accept_funder_invite_path(invite.token), params: { join_as_organisation_id: licensed_org.id }
    assert_redirected_to funder_path(fu)
    assert fu.funder_memberships.exists?(organisation: licensed_org)
    assert invite.reload.accepted?
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
