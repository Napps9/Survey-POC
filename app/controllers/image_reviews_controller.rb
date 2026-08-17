# VertoNow staff's queue of appeals against ImageModerator rejections.
#
# Appeals go to PLATFORM STAFF, not org admins: ImageModerator's "when in
# doubt, mark it not safe" prompt is a platform-level safety control, and
# letting an org admin approve their own org's upload back in is no control
# at all. Reached only through the staff routing constraint in
# config/routes.rb, the same one /ask/review uses and for the same reason —
# a non-staff request gets a 404, because the existence of this queue is
# itself something customers have no reason to learn.
class ImageReviewsController < ApplicationController
  TABS = %w[pending approved rejected].freeze

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "pending"
    @counts = {
      "pending"  => ImageReviewRequest.pending.count,
      "approved" => ImageReviewRequest.approved.count,
      "rejected" => ImageReviewRequest.rejected.count
    }
    @requests = requests_for(@tab).includes(:survey, :organisation, :user, image_attachment: :blob).limit(100)
  end

  def update
    request = ImageReviewRequest.find(params[:id])

    case params[:decision]
    when "approve" then request.approve!(reviewer_email)
    when "reject"  then request.reject!(reviewer_email)
    else return redirect_to image_reviews_path, alert: "Unknown decision."
    end

    redirect_to image_reviews_path(tab: params[:tab]), notice: "Decision recorded."
  end

  private

  def requests_for(tab)
    case tab
    when "approved" then ImageReviewRequest.approved.order(reviewed_at: :desc)
    when "rejected" then ImageReviewRequest.rejected.order(reviewed_at: :desc)
    else ImageReviewRequest.pending.order(created_at: :asc)
    end
  end

  # The routing constraint already proved this request is staff; this is
  # only for the audit trail (matches CorpusReviewsController).
  def reviewer_email
    Current.user&.email_address.to_s
  end
end
