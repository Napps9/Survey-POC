# The creator's half of the appeal flow: file one against a rejected upload,
# and list this survey's already-approved ones for the picker strip. Same org
# bar as SurveysController#moderate_image (any signed-in member, not
# admin-only) — filing an appeal grants nobody new visibility, it only asks
# staff to look. Deciding it is ImageReviewsController's job, behind the
# staff routing constraint.
class ImageAppealsController < ApplicationController
  before_action :set_survey

  # No AI call here (ImageModerator already ran, client-side, before this),
  # so this only needs a plain abuse guard, not a spend guard.
  rate_limit to: 10, within: 5.minutes, only: :create,
             with: -> { render json: { ok: false, error: "Too many requests — please try again shortly." }, status: :too_many_requests }

  # GET /surveys/:id/image_appeals — this survey's approved appeal images,
  # for the picker's "Approved by review" strip. Scoped to this survey, not
  # the whole org: an approval says this image is fine for THIS Verto's
  # audience_age, not any Verto the org happens to run.
  def index
    images = @survey.image_review_requests.approved.includes(image_attachment: :blob).order(reviewed_at: :desc).filter_map do |req|
      next unless req.image.attached?
      { id: req.id, url: rails_blob_path(req.image, only_path: true) }
    end
    render json: { ok: true, images: images }
  end

  # POST /surveys/:id/image_appeal — file an appeal against a rejected
  # upload. The client sends back the same data URL and reason it already
  # has from the failed moderate_image call; nothing here re-runs the
  # moderator (that verdict is exactly what's being appealed).
  def create
    blob = Survey::CardImageStore.attach(@survey, params[:image].to_s)
    return render json: { ok: false, error: "That doesn't look like an image." } unless blob

    request = @survey.image_review_requests.create!(
      organisation: Current.organisation,
      user:         Current.user,
      reason_given: params[:reason].to_s.strip.presence,
      note:         params[:note].to_s.strip.presence
    )
    request.image.attach(blob)

    render json: { ok: true, id: request.id }
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    ErrorReporting.report("ImageAppealsController#create", e)
    render json: { ok: false, error: "Couldn't submit that for review — please try again." }, status: :bad_gateway
  end

  private

  def set_survey
    @survey = Current.organisation.surveys.kept.find(params[:id])
  end
end
