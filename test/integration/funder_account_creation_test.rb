require "test_helper"

class FunderAccountCreationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "A", email_address: "creator-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org   = Organisation.create!(name: "Creator Co", slug: "creator-co-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @admin, role: "admin")
    @funder = @org.funders.create!(name: "Pilot Fund", seat_count: 3)
    sign_in @admin
  end

  test "admin creates a full licensed account and gets emailed a setup link" do
    email = "jamie-#{SecureRandom.hex(2)}@licensed.org"

    assert_difference [ "User.count", "Organisation.count", "Membership.count", "FunderMembership.count" ], 1 do
      assert_emails 1 do
        post funder_funder_accounts_path(@funder), params: {
          name: "Jamie Rivera",
          email_address: email,
          organisation_name: "Riverside Youth Trust"
        }
      end
    end

    assert_redirected_to funder_path(@funder)
    follow_redirect!
    assert_match email, response.body

    user = User.find_by(email_address: email)
    assert user
    assert_equal "Jamie Rivera", user.name
    assert user.password_pending?

    membership = user.memberships.first
    assert_equal "admin", membership.role
    assert_equal "Riverside Youth Trust", membership.organisation.name

    assert FunderMembership.exists?(funder: @funder, organisation: membership.organisation, status: "active")

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ email ], mail.to
    assert_match "Pilot Fund", mail.subject

    setup_url = mail.html_part.body.to_s[%r{http://\S+/funder_account_setups/(\S+)/edit}, 0]
    assert setup_url, "expected a funder_account_setups edit link in the email body"
    delete session_path
    get setup_url
    assert_response :success
  end

  test "rejects an email that already has an account" do
    existing = User.create!(name: "Existing", email_address: "taken-#{SecureRandom.hex(2)}@licensed.org", password: "verylongpassword")

    assert_no_difference [ "User.count", "Organisation.count" ] do
      post funder_funder_accounts_path(@funder), params: {
        name: "Jamie", email_address: existing.email_address,
        organisation_name: "New Org"
      }
    end
    assert_response :unprocessable_entity
    assert_match "already has a Playverto account", response.body
  end

  test "rejects missing fields" do
    assert_no_difference "User.count" do
      post funder_funder_accounts_path(@funder), params: {
        name: "", email_address: "x@licensed.org", organisation_name: "New Org"
      }
    end
    assert_response :unprocessable_entity
  end

  test "a non-admin member cannot create a licensed account" do
    member = User.create!(name: "M", email_address: "member-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: member, role: "member")
    delete session_path
    sign_in member

    assert_no_difference "User.count" do
      post funder_funder_accounts_path(@funder), params: {
        name: "Jamie", email_address: "jamie3-#{SecureRandom.hex(2)}@licensed.org",
        organisation_name: "New Org"
      }
    end
    assert_response :redirect
  end

  test "an admin of a different org cannot create an account for a funder they don't own" do
    other_admin = User.create!(name: "O", email_address: "other-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    other_org   = Organisation.create!(name: "Other Co", slug: "other-co-#{SecureRandom.hex(2)}")
    other_org.memberships.create!(user: other_admin, role: "admin")
    delete session_path
    sign_in other_admin

    assert_no_difference "User.count" do
      post funder_funder_accounts_path(@funder), params: {
        name: "Jamie", email_address: "jamie4-#{SecureRandom.hex(2)}@licensed.org",
        organisation_name: "New Org"
      }
    end
    assert_response :not_found
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
