require "test_helper"

class WizardSmokeTest < ActionDispatch::IntegrationTest
  test "/surveys/new renders Step 7 with populate_content radios" do
    user = User.create!(name: "U", email_address: "ws-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "ws-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get new_survey_path
    assert_response :success
    # The new step text
    assert_match "How would you like to start?", response.body
    assert_match "Populate content", response.body
    assert_match "Start from blank", response.body
    # The hidden form field
    assert_match 'name="populate_content" value="1"', response.body
    assert_match 'name="populate_content" value="0"', response.body
    # Step counter bumped from 7 to 8
    assert_match "Step 1 of 8", response.body
  end
end
