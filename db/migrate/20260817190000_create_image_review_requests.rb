class CreateImageReviewRequests < ActiveRecord::Migration[8.1]
  # An appeal against a rejected upload — the moderation twin of SurveyLink's
  # revoke/reset lifecycle, except the decision belongs to VertoNow staff, not
  # the org (see ImageReviewsController's class comment for why: an org
  # approving its own rejected upload is no control at all).
  def change
    create_table :image_review_requests do |t|
      t.references :organisation, null: false, foreign_key: true
      t.references :survey,       null: false, foreign_key: true
      t.references :user,         null: false, foreign_key: true

      # ImageModerator's verdict at rejection time, copied here so a reviewer
      # sees why it was rejected without re-running the moderator against an
      # image that (if approved) will never be checked again.
      t.text :reason_given
      # The creator's own case for the image, if they left one — optional,
      # so filing an appeal is never blocked on writing something.
      t.text :note

      t.string :status, null: false, default: "pending"
      t.string :reviewed_by_email
      t.datetime :reviewed_at

      t.timestamps
    end

    # The queue's own query (pending, oldest first) and the picker strip's
    # query (approved, scoped to one survey) — see ImageReviewsController and
    # ImageAppealsController.
    add_index :image_review_requests, [ :status, :created_at ]
    add_index :image_review_requests, [ :survey_id, :status ]

    add_check_constraint :image_review_requests,
      "status IN ('pending', 'approved', 'rejected')",
      name: "chk_image_review_requests_status"
  end
end
