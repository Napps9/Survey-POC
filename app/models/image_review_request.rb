# A creator's appeal against an upload ImageModerator rejected.
#
# Decisions belong to VertoNow staff, never the org that filed the appeal —
# see ImageReviewsController's class comment for why self-approval is no
# control. The image itself is persisted as an ActiveStorage blob (via
# Survey::CardImageStore.attach, the same decode/validate/attach path a card
# upload already goes through) rather than a data-URL column — see that
# model's header for the production-502 history behind that rule.
class ImageReviewRequest < ApplicationRecord
  belongs_to :organisation
  belongs_to :survey
  belongs_to :user

  has_one_attached :image

  enum :status, { pending: "pending", approved: "approved", rejected: "rejected" }

  # Approval bypasses re-moderation structurally, not by overriding the
  # moderator: media_picker_controller.js only moderates data: URLs, and an
  # approved appeal's tile carries a same-origin blob path — see
  # applyImage()'s comment. Nothing here needs to remember that; it's just
  # where the URL comes from.
  def approve!(reviewer_email)
    update!(status: "approved", reviewed_at: Time.current, reviewed_by_email: reviewer_email)
  end

  def reject!(reviewer_email)
    update!(status: "rejected", reviewed_at: Time.current, reviewed_by_email: reviewer_email)
  end
end
