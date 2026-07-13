require "test_helper"

class WizardSmokeTest < ActionDispatch::IntegrationTest
  test "/surveys/new renders the combined Final-touches step with brand picker" do
    user = User.create!(name: "U", email_address: "ws-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "ws-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get new_survey_path
    assert_response :success
    # Combined-step copy and section headers
    assert_match "Final touches", response.body
    assert_match "Brand colours", response.body
    # The "How to start? Populate / Blank" choice was removed: every new Verto
    # is auto-populated with imagery on create.
    refute_match "How to start", response.body
    refute_match 'name="populate_content"', response.body
    # Brand-palette inputs live on the same card
    assert_match 'name="brand_palette[primary]"', response.body
    assert_match 'name="brand_palette[cta]"', response.body
    assert_match 'name="brand_palette[bg]"', response.body
    # 8 cards: brief steps plus the final "Have your own questions?" card
    assert_match "Step 1 of 8", response.body
    # PDF import is an optional, collapsed alternative (not a mandatory step):
    # it lives inside a <details> disclosure, and the Generate finish button is
    # still present as the primary path.
    assert_match "import-pdf-disclosure", response.body
    assert_match "Generate Verto", response.body
    assert_match "Import them instead", response.body
  end

  test "language pickers use English names, not flag emoji" do
    user = User.create!(name: "U", email_address: "ws-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "ws-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get new_survey_path
    assert_response :success
    # The Languages card labels each language by its English name…
    assert_match ">Spanish<", response.body
    assert_match ">Swahili<", response.body
    refute_match "Español", response.body
    # …and no flag emoji (regional-indicator pairs) anywhere on the page.
    refute_match(/[\u{1F1E6}-\u{1F1FF}]/, response.body)
  end
end
