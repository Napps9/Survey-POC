require "test_helper"

# The creator's half of the moderation-appeal flow: file one against a
# rejected upload, and list this survey's already-approved ones for the
# picker strip. Deciding an appeal is ImageReviewsController's job, behind
# the staff routing constraint — see image_reviews_test.rb.
class ImageAppealsTest < ActionDispatch::IntegrationTest
  PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  def setup
    @user = User.create!(name: "U", email_address: "ia-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ia-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "member")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "T", theme: "Space", audience_age: "under 10s",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
  end

  test "filing an appeal attaches the image and creates a pending request" do
    post image_appeal_survey_path(@survey), params: { image: PNG, reason: "shows alcohol", note: "it's a soda can" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]

    req = ImageReviewRequest.find(body["id"])
    assert_equal @survey.id, req.survey_id
    assert_equal @org.id, req.organisation_id
    assert_equal @user.id, req.user_id
    assert req.pending?
    assert_equal "shows alcohol", req.reason_given
    assert_equal "it's a soda can", req.note
    assert req.image.attached?
  end

  test "a non-image payload is rejected" do
    post image_appeal_survey_path(@survey), params: { image: "not-an-image" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["ok"]
    assert_equal 0, @survey.image_review_requests.count
  end

  test "any signed-in org member can file — this is not admin-gated" do
    # setup already signed in as a plain "member", not "admin".
    assert_equal "member", @org.memberships.find_by(user: @user).role

    post image_appeal_survey_path(@survey), params: { image: PNG }, as: :json
    assert_response :success
    assert_equal true, JSON.parse(response.body)["ok"]
  end

  test "another org's survey is not reachable" do
    other = Organisation.create!(name: "X", slug: "ia2-#{SecureRandom.hex(2)}")
    s2 = other.surveys.create!(title: "S2", theme: "t", audience_age: "all",
                               key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
    post image_appeal_survey_path(s2), params: { image: PNG }, as: :json
    assert_response :not_found
  end

  test "the approved list only returns approved requests for this survey" do
    pending  = @survey.image_review_requests.create!(organisation: @org, user: @user)
    rejected = @survey.image_review_requests.create!(organisation: @org, user: @user).tap { |r| r.reject!("staff@vertonow.com") }
    approved = @survey.image_review_requests.create!(organisation: @org, user: @user)
    approved.image.attach(io: StringIO.new(Base64.decode64(PNG.split(",").last)), filename: "a.png", content_type: "image/png")
    approved.approve!("staff@vertonow.com")

    other_survey = @org.surveys.create!(title: "T2", theme: "t2", audience_age: "all",
                                        key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
    elsewhere = other_survey.image_review_requests.create!(organisation: @org, user: @user)
    elsewhere.image.attach(io: StringIO.new(Base64.decode64(PNG.split(",").last)), filename: "b.png", content_type: "image/png")
    elsewhere.approve!("staff@vertonow.com")

    get image_appeals_survey_path(@survey), as: :json
    assert_response :success
    images = JSON.parse(response.body)["images"]
    assert_equal 1, images.size
    assert_equal approved.id, images.first["id"]
    refute pending.approved?
    refute rejected.approved?
  end

  test "the approved list is empty (not an error) when there's nothing to show" do
    get image_appeals_survey_path(@survey), as: :json
    assert_response :success
    assert_equal [], JSON.parse(response.body)["images"]
  end
end
