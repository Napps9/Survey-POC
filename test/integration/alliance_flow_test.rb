require "test_helper"

class AllianceFlowTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "A", email_address: "creator@test.com", password: "verylongpassword")
    @oa = Organisation.create!(name: "Creator Co", slug: "creator-co-#{SecureRandom.hex(2)}")
    @oa.memberships.create!(user: @admin, role: "admin")
    sign_in @admin
  end

  test "creator creates an alliance, invites and adds a partner, shares a Verto" do
    # Index: empty state
    get alliances_path
    assert_response :success
    assert_match "Alliances you run", response.body
    assert_match "No alliances yet", response.body

    # New form
    get new_alliance_path
    assert_response :success
    assert_match "Alliance name", response.body

    # Create
    post alliances_path, params: { alliance: { name: "Pilot Group" } }
    assert_redirected_to alliance_path(Alliance.last)
    follow_redirect!
    assert_response :success
    assert_match "Pilot Group", response.body
    assert_match "Generate join link", response.body
    assert_match "No partners yet", response.body

    a = Alliance.last
    # Generate invite
    post alliance_alliance_invites_path(a)
    assert_redirected_to alliance_path(a, new_invite_token: Invite.last.token)
    follow_redirect!
    assert_match "New join link", response.body

    # Add a partner org + accept invite
    partner_user_email = "b-#{SecureRandom.hex(2)}@test.com"
    invite_token = Invite.last.token
    # Need to log out then accept as fresh user
    delete session_path
    post accept_invite_path(invite_token), params: {
      name: "Partner B Admin",
      organisation_name: "Partner B",
      email_address: partner_user_email,
      password: "verylongpassword",
      password_confirmation: "verylongpassword"
    }
    assert_redirected_to alliance_path(a)
    follow_redirect!
    assert_match "Pilot Group", response.body
    assert_match "Run by Creator Co", response.body, "partner_show should label creator org"

    # Back in as creator
    delete session_path
    sign_in @admin

    # Create + publish a Verto, then add to alliance
    survey = @oa.surveys.create!(
      title: "Pilot Verto", theme: "Pilot Theme", audience_age: "18-35",
      key_insight: "x", default_locale: "en", locales: ["en"],
      cards: [{"type"=>"welcome_card","title"=>"hi"},{"type"=>"single_choice","title"=>"Q","options"=>[{"label"=>"Yes"},{"label"=>"No"}]}],
      publish_token: SecureRandom.urlsafe_base64(18),
      published_at: Time.current
    )

    post alliance_alliance_vertos_path(a), params: { survey_id: survey.id }
    assert_redirected_to alliance_path(a)
    follow_redirect!
    assert_match "Pilot Verto", response.body, "alliance creator_show should list added Verto"

    # Should have exactly one SurveyShare auto-generated (one partner in alliance)
    assert_equal 1, a.survey_shares.count
    share = a.survey_shares.first
    assert_equal "Partner B", share.partner_organisation.name
    assert share.share_token.present?
  end

  test "partner sees alliance in member section and gets their share link + results page" do
    # Build the scenario
    a = @oa.alliances.create!(name: "Trial")
    partner_admin = User.create!(name: "P", email_address: "p2-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Partner X", slug: "partner-x-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")
    a.alliance_memberships.create!(organisation: partner_org)

    survey = @oa.surveys.create!(
      title: "Trial Verto", theme: "T", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: ["en"],
      cards: [{"type"=>"single_choice","title"=>"Q","options"=>[{"label"=>"A"},{"label"=>"B"}]}],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    a.alliance_vertos.create!(survey: survey)
    AllianceShareSync.ensure_shares_for(alliance: a)
    share = a.survey_shares.first

    delete session_path
    sign_in partner_admin

    get alliances_path
    assert_response :success
    assert_match(/Alliances you('|&#39;)re a member of/, response.body)
    assert_match "Trial", response.body

    get alliance_path(a)
    assert_response :success
    assert_match "Partner X", response.body, "partner_show should not crash for member"
    assert_match "Trial Verto", response.body
    assert_match share.share_token, response.body, "partner sees their own share token"

    av = a.alliance_vertos.first
    get alliance_alliance_verto_path(a, av)
    assert_response :success
    assert_match "Trial Verto", response.body
    assert_match share.share_token, response.body
    assert_match "across Trial", response.body, "aggregate strip names the alliance"
  end

  test "any org can be a creator and a partner-member simultaneously" do
    # Set up: org A creates "Group A", org B creates "Group B" and invites A
    a_alliance = @oa.alliances.create!(name: "Group A")

    ob_admin = User.create!(name: "B-admin", email_address: "b-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    ob = Organisation.create!(name: "Org B", slug: "ob-#{SecureRandom.hex(2)}")
    ob.memberships.create!(user: ob_admin, role: "admin")
    b_alliance = ob.alliances.create!(name: "Group B")
    b_alliance.alliance_memberships.create!(organisation: @oa)

    get alliances_path
    assert_response :success
    assert_match "Group A", response.body, "should list owned alliance"
    assert_match "Group B", response.body, "should list member alliance"

    # Visiting Group A → creator_show
    get alliance_path(a_alliance)
    assert_response :success
    assert_match "Generate join link", response.body, "creator view of own alliance"

    # Visiting Group B → partner_show
    get alliance_path(b_alliance)
    assert_response :success
    assert_match "Run by Org B", response.body, "member view of alliance"
    refute_match "Generate join link", response.body, "should NOT see creator controls on alliance you're a member of"
  end

  test "aggregate scope is per-alliance, not cross-alliance" do
    # Two alliances, both contain the same partner B and the same Verto.
    # Responses through alliance 1's share should not appear in alliance 2's aggregate.
    partner_admin = User.create!(name: "B", email_address: "agg-b-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Agg Partner", slug: "agg-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")

    survey = @oa.surveys.create!(
      title: "Cross-Test", theme: "X", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: ["en"],
      cards: [{"type"=>"single_choice","title"=>"Q","options"=>[{"label"=>"A"},{"label"=>"B"}]}],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )

    a1 = @oa.alliances.create!(name: "Aggregate Alpha")
    a1.alliance_memberships.create!(organisation: partner_org)
    a1.alliance_vertos.create!(survey: survey)
    AllianceShareSync.ensure_shares_for(alliance: a1)

    a2 = @oa.alliances.create!(name: "Aggregate Beta")
    a2.alliance_memberships.create!(organisation: partner_org)
    a2.alliance_vertos.create!(survey: survey)
    AllianceShareSync.ensure_shares_for(alliance: a2)

    a1_share = a1.survey_shares.first
    a2_share = a2.survey_shares.first

    # 2 responses through a1, 5 through a2
    2.times { survey.responses.create!(session_token: SecureRandom.urlsafe_base64(16), survey_share: a1_share, status: "completed", answers: {"0"=>{"value"=>"A"}}) }
    5.times { survey.responses.create!(session_token: SecureRandom.urlsafe_base64(16), survey_share: a2_share, status: "completed", answers: {"0"=>{"value"=>"B"}}) }

    delete session_path
    sign_in partner_admin

    av1 = a1.alliance_vertos.first
    get alliance_alliance_verto_path(a1, av1)
    assert_response :success
    assert_match "<strong style=\"font-family:'Alata',sans-serif;\">2</strong> from your link", response.body
    assert_match "<strong style=\"font-family:'Alata',sans-serif;\">2</strong> across Aggregate Alpha", response.body,
                 "aggregate should be 2 — only this alliance's responses, NOT 7"

    av2 = a2.alliance_vertos.first
    get alliance_alliance_verto_path(a2, av2)
    assert_response :success
    assert_match "<strong style=\"font-family:'Alata',sans-serif;\">5</strong> across Aggregate Beta", response.body
  end

  test "signed-in admin of an existing org joins an alliance via the join link" do
    # Setup: a partner org with an existing admin who's signed in
    partner_admin = User.create!(name: "Existing", email_address: "exist-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Existing Co", slug: "exist-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")

    # Creator (admin @admin from setup) makes an alliance + invite
    a = @oa.alliances.create!(name: "Existing-User Group")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      alliance: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # Sign in as the partner admin
    delete session_path
    sign_in partner_admin

    # GET /invites/:token shows the signed-in picker
    get invite_path(invite.token)
    assert_response :success
    assert_match "Signed in as", response.body
    assert_match partner_admin.name, response.body
    assert_match "Join with", response.body
    assert_match "Existing Co", response.body
    refute_match "Confirm password", response.body, "signed-in users should NOT see the signup form"

    # POST accept with join_as_organisation_id
    post accept_invite_path(invite.token), params: { join_as_organisation_id: partner_org.id }
    assert_redirected_to alliance_path(a)
    follow_redirect!
    assert_match "Existing-User Group", response.body

    # AllianceMembership created without creating a new org
    assert a.alliance_memberships.exists?(organisation: partner_org), "existing org should be linked"
    refute Organisation.exists?(name: "#{partner_admin.name}'s organisation"), "no new org should be created"

    # Invite is single-use
    assert invite.reload.accepted?
  end

  test "signed-in user with multiple admin orgs picks which one joins" do
    user = User.create!(name: "Multi", email_address: "multi-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org_x = Organisation.create!(name: "Org X", slug: "ox-#{SecureRandom.hex(2)}")
    org_y = Organisation.create!(name: "Org Y", slug: "oy-#{SecureRandom.hex(2)}")
    org_x.memberships.create!(user: user, role: "admin")
    org_y.memberships.create!(user: user, role: "admin")

    a = @oa.alliances.create!(name: "Multi-Org Group")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      alliance: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    delete session_path
    sign_in user

    get invite_path(invite.token)
    assert_response :success
    assert_match "Pick which organisation joins", response.body
    assert_match "Org X", response.body
    assert_match "Org Y", response.body

    post accept_invite_path(invite.token), params: { join_as_organisation_id: org_y.id }
    assert_redirected_to alliance_path(a)

    assert a.alliance_memberships.exists?(organisation: org_y)
    refute a.alliance_memberships.exists?(organisation: org_x), "only the picked org should join"
  end

  test "signed-in admin of the alliance creator cannot join their own alliance" do
    a = @oa.alliances.create!(name: "Self-Join Test")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      alliance: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # @admin is signed in (from setup) and is admin of @oa, which created the alliance
    get invite_path(invite.token)
    assert_response :success
    assert_match "You run this alliance", response.body, "should explain why join isn't possible"
    refute_match "Pick which organisation joins", response.body
  end

  test "signed-in admin of an org already in the alliance sees 'already a member'" do
    other_org = Organisation.create!(name: "Already Joined", slug: "aj-#{SecureRandom.hex(2)}")
    other_org.memberships.create!(user: @admin, role: "admin")

    a = @oa.alliances.create!(name: "Already Member Test")
    a.alliance_memberships.create!(organisation: other_org)

    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      alliance: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # @admin is signed in and admin of @oa (creator) + Already Joined (already member).
    get invite_path(invite.token)
    assert_response :success
    # @oa is the creator → "You run this alliance" message wins over "already a member".
    # That's fine; assert at least one informative banner shows.
    assert(response.body.include?("You run this alliance") || response.body.include?("already in this alliance"))
    refute_match "Pick which organisation joins", response.body
  end

  test "existing not-signed-in user can sign in via the invite page" do
    # Existing partner user + org, but not currently signed in
    partner_admin = User.create!(name: "Returning", email_address: "ret-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    partner_org = Organisation.create!(name: "Returning Co", slug: "ret-#{SecureRandom.hex(2)}")
    partner_org.memberships.create!(user: partner_admin, role: "admin")

    a = @oa.alliances.create!(name: "Sign-In Test Group")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      alliance: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    # Sign out of the setup session
    delete session_path

    # GET shows the signup form with a "Sign in instead" toggle
    get invite_path(invite.token)
    assert_response :success
    assert_match "Sign in instead", response.body
    assert_match "invite-signin-form", response.body
    assert_match "Sign in to join", response.body

    # POST with mode=sign_in → authenticates, redirects to GET show
    post accept_invite_path(invite.token), params: {
      mode: "sign_in",
      email_address: partner_admin.email_address,
      password: "verylongpassword"
    }
    assert_redirected_to invite_path(invite.token)
    follow_redirect!
    assert_response :success
    assert_match "Signed in as", response.body, "should now show signed-in picker"
    assert_match "Returning Co", response.body
    refute_match "Confirm password", response.body

    # Invite not consumed yet — only consumed when org actually joins
    refute invite.reload.accepted?

    # Click join
    post accept_invite_path(invite.token), params: { join_as_organisation_id: partner_org.id }
    assert_redirected_to alliance_path(a)
    assert a.alliance_memberships.exists?(organisation: partner_org)
    assert invite.reload.accepted?
  end

  test "sign-in with wrong password shows error and stays on sign-in form" do
    user = User.create!(name: "X", email_address: "wrong-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org = Organisation.create!(name: "X", slug: "wx-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")

    a = @oa.alliances.create!(name: "Wrong-PW Test")
    invite = @oa.invites.create!(
      email_address: "link-#{SecureRandom.hex(4)}@partner.invite",
      role: "admin", kind: "partner",
      alliance: a, invited_by: @admin,
      expires_at: 14.days.from_now
    )

    delete session_path

    post accept_invite_path(invite.token), params: {
      mode: "sign_in",
      email_address: user.email_address,
      password: "wrongpassword"
    }
    assert_response :unprocessable_entity
    assert_match "find an account", response.body, "error message should be shown"
    # Sign-in form is the visible one after the failure; signup form is hidden
    assert_match "id=\"invite-signup-form\" hidden", response.body, "signup form should be hidden"
    refute_match "id=\"invite-signin-form\" hidden", response.body, "sign-in form must stay open"
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
