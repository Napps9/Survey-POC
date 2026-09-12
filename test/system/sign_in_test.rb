require "application_system_test_case"

# The sign-in form, driven for real. Every other system test signs in by
# minting the session cookie (ApplicationSystemTestCase#sign_in_as), so this
# is where the form itself keeps a browser test.
class SignInTest < ApplicationSystemTestCase
  def setup
    super
    @user = User.create!(name: "S", email_address: "si-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    # A user with no organisation is sent back to the sign-in page by
    # OrganisationScope; the form is what is under test here, not that rule.
    org = Organisation.create!(name: "O", slug: "si-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: @user, role: "admin")
  end

  test "the right password signs in and leaves the sign-in page" do
    sign_in_through_form(@user)

    assert_no_current_path new_session_path
    assert_equal 1, @user.sessions.count
  end

  test "the wrong password stays on the sign-in page and says so" do
    visit new_session_path
    fill_in "email_address", with: @user.email_address
    fill_in "password", with: "not-the-password"
    find("input[name=password]").send_keys(:enter)

    assert_text I18n.t("flash.sessions.invalid_credentials"), wait: 5
    assert_current_path new_session_path
    assert_equal 0, @user.sessions.count
  end
end
