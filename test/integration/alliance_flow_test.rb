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
    assert_match "Alliances you're a member of", response.body
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

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
