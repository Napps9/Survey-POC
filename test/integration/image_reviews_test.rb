require "test_helper"

# VertoNow staff's queue of appeals against ImageModerator rejections.
# Mounted behind the same staff routing constraint as /ask/review and
# /blazer, so these cover the security boundary first (mirrors
# blazer_access_test.rb) before exercising the decision itself.
class ImageReviewsTest < ActionDispatch::IntegrationTest
  PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  def setup
    @original_env = ENV["BLAZER_STAFF_EMAILS"]
    @org   = Organisation.create!(name: "O", slug: "ir-#{SecureRandom.hex(3)}")
    @staff = make_user("staff@vertonow.com")
    @other = make_user("member@customer.com")
    @survey = @org.surveys.create!(title: "T", theme: "Space", audience_age: "under 10s",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
  end

  def teardown
    if @original_env.nil?
      ENV.delete("BLAZER_STAFF_EMAILS")
    else
      ENV["BLAZER_STAFF_EMAILS"] = @original_env
    end
  end

  def make_user(email)
    User.create!(name: "U", email_address: email, password: "verylongpassword").tap do |u|
      @org.memberships.create!(user: u, role: "member")
    end
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def build_appeal(reason: "shows alcohol")
    @survey.image_review_requests.create!(organisation: @org, user: @other, reason_given: reason)
  end

  test "a signed-in non-staff user cannot reach the queue" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @other
    get "/image_reviews"
    assert_response :not_found
  end

  test "deny-by-default: staff is blocked while the allowlist is unset" do
    ENV.delete("BLAZER_STAFF_EMAILS")
    sign_in @staff
    get "/image_reviews"
    assert_response :not_found
  end

  test "a staff user on the allowlist reaches the queue" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @staff
    get "/image_reviews"
    assert_response :success
  end

  test "approving stamps the reviewer and moves the request out of pending" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @staff
    req = build_appeal

    patch "/image_reviews/#{req.id}", params: { decision: "approve", tab: "pending" }
    assert_redirected_to image_reviews_path(tab: "pending")
    req.reload
    assert req.approved?
    assert_equal "staff@vertonow.com", req.reviewed_by_email
  end

  test "rejecting stamps the reviewer" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @staff
    req = build_appeal

    patch "/image_reviews/#{req.id}", params: { decision: "reject", tab: "pending" }
    req.reload
    assert req.rejected?
    assert_equal "staff@vertonow.com", req.reviewed_by_email
  end

  test "a non-staff user cannot approve — the route itself doesn't exist for them" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @other
    req = build_appeal

    patch "/image_reviews/#{req.id}", params: { decision: "approve" }
    assert_response :not_found
    refute req.reload.approved?
  end

  test "the pending tab only lists pending requests, counted correctly" do
    ENV["BLAZER_STAFF_EMAILS"] = "staff@vertonow.com"
    sign_in @staff
    pending  = build_appeal
    approved = build_appeal.tap { |r| r.approve!("staff@vertonow.com") }

    get "/image_reviews", params: { tab: "pending" }
    assert_response :success
    assert_match pending.survey.title, response.body
    refute_match(/Approved #{Regexp.escape(approved.reviewed_by_email)}/, response.body)
  end
end
