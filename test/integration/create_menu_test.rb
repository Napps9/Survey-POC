require "test_helper"

# The dashboard's "+ Create" popup: the four create tiles, the Form flow's
# rename to "Create New Form", and the cross-links back into it (from the
# template gallery) that make an import path reachable no matter which
# create option a creator starts from.
class CreateMenuTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "cm-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "cm-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    @org.surveys.create!(title: "Existing", theme: "T", audience_age: "a", key_insight: "k", default_locale: "en", locales: [ "en" ])
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "the dashboard shows the Create popup's four tiles and the renamed scratch button" do
    get root_path
    assert_response :success
    assert_match "Impact Measurement", response.body
    assert_match "Quiz", response.body
    assert_match ">Form<", response.body
    assert_match "Template", response.body
    assert_match "Create New Form", response.body
    refute_match "Start from scratch", response.body
    # Impact Measurement / Quiz mention the import alternative that already
    # lives at the end of their wizard (Card 8).
    assert_match "or import your own questions", response.body
  end

  test "the template gallery links back to the dashboard's import panel" do
    get survey_templates_path
    assert_response :success
    assert_match "Import instead", response.body
    assert_match root_path(open_import: 1), response.body
  end

  test "?open_import=1 reopens the Create popup straight into the Form panel" do
    get root_path(open_import: 1)
    assert_response :success
    assert_match 'data-create-menu-reopen-value="true"', response.body
  end
end
