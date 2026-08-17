require "test_helper"

class ImageReviewRequestTest < ActiveSupport::TestCase
  def setup
    @org  = Organisation.create!(name: "O", slug: "irr-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "irr-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "member")
    @survey = @org.surveys.create!(title: "T", theme: "Space", audience_age: "under 10s",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
  end

  def build_request(**attrs)
    @survey.image_review_requests.create!(organisation: @org, user: @user, **attrs)
  end

  test "starts pending" do
    req = build_request
    assert req.pending?
    assert_equal "pending", req.status
  end

  test "an unknown status is rejected by the Ruby enum before it ever reaches the database" do
    req = build_request
    assert_raises(ArgumentError) { req.status = "sort_of" }
  end

  # Matches CorpusEntry's own test for its review_status column: the enum
  # guards ordinary Active Record writes, but a console session or a future
  # bulk update goes around it — update_columns skips validations/callbacks
  # while still issuing a real UPDATE, so the database CHECK is what actually
  # stops it here, not the model.
  test "status is constrained in the database, not just the model" do
    req = build_request
    assert_raises(ActiveRecord::StatementInvalid) do
      req.update_columns(status: "sort_of")
    end
  end

  test "approve! stamps the reviewer and timestamp" do
    req = build_request(reason_given: "shows alcohol")
    req.approve!("staff@vertonow.com")

    assert req.reload.approved?
    assert_equal "staff@vertonow.com", req.reviewed_by_email
    assert req.reviewed_at.present?
  end

  test "reject! stamps the reviewer and timestamp" do
    req = build_request
    req.reject!("staff@vertonow.com")

    assert req.reload.rejected?
    assert_equal "staff@vertonow.com", req.reviewed_by_email
    assert req.reviewed_at.present?
  end

  test "pending/approved/rejected scopes only return their own status" do
    pending  = build_request
    approved = build_request.tap { |r| r.approve!("staff@vertonow.com") }
    rejected = build_request.tap { |r| r.reject!("staff@vertonow.com") }

    assert_equal [ pending ], ImageReviewRequest.pending.where(id: [ pending, approved, rejected ])
    assert_equal [ approved ], ImageReviewRequest.approved.where(id: [ pending, approved, rejected ])
    assert_equal [ rejected ], ImageReviewRequest.rejected.where(id: [ pending, approved, rejected ])
  end

  test "requires an organisation, survey and user" do
    assert_raises(ActiveRecord::RecordInvalid) { ImageReviewRequest.create!(survey: @survey, user: @user) }
    assert_raises(ActiveRecord::RecordInvalid) { ImageReviewRequest.create!(organisation: @org, user: @user) }
    assert_raises(ActiveRecord::RecordInvalid) { ImageReviewRequest.create!(organisation: @org, survey: @survey) }
  end

  test "destroying the survey destroys its appeals" do
    req = build_request
    @survey.destroy
    assert_nil ImageReviewRequest.find_by(id: req.id)
  end
end
