require "test_helper"

class WizardSmokeTest < ActionDispatch::IntegrationTest
  test "/surveys/new renders the combined Final-touches step with populate radios + brand picker" do
    user = User.create!(name: "U", email_address: "ws-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "ws-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get new_survey_path
    assert_response :success
    # Combined-step copy and section headers
    assert_match "Final touches", response.body
    assert_match "How to start", response.body
    assert_match "Brand colours", response.body
    # Populate choice labels
    assert_match "Populate content", response.body
    assert_match "Start from New", response.body
    # The hidden form field
    assert_match 'name="populate_content" value="1"', response.body
    assert_match 'name="populate_content" value="0"', response.body
    # Brand-palette inputs live on the same card
    assert_match 'name="brand_palette[primary]"', response.body
    assert_match 'name="brand_palette[cta]"', response.body
    assert_match 'name="brand_palette[bg]"', response.body
    # Wizard reduced from 8 → 7 cards
    assert_match "Step 1 of 7", response.body
    # PDF import is an optional, collapsed alternative (not a mandatory step):
    # it lives inside a <details> disclosure, and the Generate finish button is
    # still present as the primary path.
    assert_match "import-pdf-disclosure", response.body
    assert_match "Generate Verto", response.body
    assert_match "Import them instead", response.body
  end
end
