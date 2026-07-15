require "test_helper"

class FunderAccountSetupTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "A", email_address: "creator-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org   = Organisation.create!(name: "Creator Co", slug: "creator-co-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @admin, role: "admin")
    @funder = @org.funders.create!(name: "Pilot Fund", seat_count: 3)

    @licensed_user = User.create!(
      name: "Jamie", email_address: "jamie-#{SecureRandom.hex(2)}@licensed.org",
      password: SecureRandom.hex(32), password_pending: true
    )
    @licensed_org = Organisation.create!(name: "Licensed Org", slug: "licensed-org-#{SecureRandom.hex(2)}")
    @licensed_org.memberships.create!(user: @licensed_user, role: "admin")
    FunderMembership.assign!(funder: @funder, organisation: @licensed_org)
  end

  test "a valid token lets the licensed org's admin set their password, signs them in, and lands on the funder dashboard" do
    token = @licensed_user.generate_token_for(:account_setup)

    get edit_funder_account_setup_path(token)
    assert_response :success

    patch funder_account_setup_path(token), params: {
      password: "brandnewpassword", password_confirmation: "brandnewpassword"
    }
    assert_redirected_to funder_path(@funder)
    follow_redirect!
    assert_response :success

    @licensed_user.reload
    refute @licensed_user.password_pending?
    assert @licensed_user.authenticate("brandnewpassword")
  end

  test "an invalid token shows a friendly error instead of crashing" do
    get edit_funder_account_setup_path("not-a-real-token")
    assert_redirected_to new_session_path
    assert_match "invalid or has expired", flash[:alert]
  end

  test "an expired token shows a friendly error" do
    token = @licensed_user.generate_token_for(:account_setup)
    travel 8.days do
      get edit_funder_account_setup_path(token)
      assert_redirected_to new_session_path
    end
  end

  test "mismatched password confirmation re-renders with an error" do
    token = @licensed_user.generate_token_for(:account_setup)

    patch funder_account_setup_path(token), params: {
      password: "brandnewpassword", password_confirmation: "somethingelse"
    }
    assert_redirected_to edit_funder_account_setup_path(token)
    follow_redirect!
    assert @licensed_user.reload.password_pending?
  end
end
