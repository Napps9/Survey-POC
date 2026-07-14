require "test_helper"

class PartnerAccountSetupTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "A", email_address: "creator-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org   = Organisation.create!(name: "Creator Co", slug: "creator-co-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @admin, role: "admin")
    @partnership = @org.partnerships.create!(name: "Pilot Group")

    @partner_user = User.create!(
      name: "Jamie", email_address: "jamie-#{SecureRandom.hex(2)}@partner.org",
      password: SecureRandom.hex(32), password_pending: true
    )
    @partner_org = Organisation.create!(name: "Partner Org", slug: "partner-org-#{SecureRandom.hex(2)}")
    @partner_org.memberships.create!(user: @partner_user, role: "admin")
    PartnershipMembership.join!(partnership: @partnership, organisation: @partner_org)
  end

  test "a valid token lets the partner set their password, signs them in, and lands on the partnership dashboard" do
    token = @partner_user.generate_token_for(:account_setup)

    get edit_partner_account_setup_path(token)
    assert_response :success

    patch partner_account_setup_path(token), params: {
      password: "brandnewpassword", password_confirmation: "brandnewpassword"
    }
    assert_redirected_to partnership_path(@partnership)
    follow_redirect!
    assert_response :success

    @partner_user.reload
    refute @partner_user.password_pending?
    assert @partner_user.authenticate("brandnewpassword")
  end

  test "an invalid token shows a friendly error instead of crashing" do
    get edit_partner_account_setup_path("not-a-real-token")
    assert_redirected_to new_session_path
    assert_match "invalid or has expired", flash[:alert]
  end

  test "an expired token shows a friendly error" do
    token = @partner_user.generate_token_for(:account_setup)
    travel 8.days do
      get edit_partner_account_setup_path(token)
      assert_redirected_to new_session_path
    end
  end

  test "mismatched password confirmation re-renders with an error" do
    token = @partner_user.generate_token_for(:account_setup)

    patch partner_account_setup_path(token), params: {
      password: "brandnewpassword", password_confirmation: "somethingelse"
    }
    assert_redirected_to edit_partner_account_setup_path(token)
    follow_redirect!
    assert @partner_user.reload.password_pending?
  end

  test "the generic forgot-password flow also clears password_pending" do
    post passwords_path, params: { email_address: @partner_user.email_address }
    token = @partner_user.password_reset_token

    patch password_path(token), params: {
      password: "anothernewpassword", password_confirmation: "anothernewpassword"
    }
    assert_redirected_to new_session_path
    refute @partner_user.reload.password_pending?
  end
end
