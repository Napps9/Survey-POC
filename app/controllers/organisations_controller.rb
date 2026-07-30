class OrganisationsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!, only: [ :edit, :update ]

  def switch
    organisation_id = params[:organisation_id].to_i
    if Current.user.organisations.exists?(organisation_id)
      session[:current_organisation_id] = organisation_id
    end
    redirect_to root_path
  end

  def edit
    @organisation = current_organisation
  end

  def update
    @organisation = current_organisation

    # `params.require` raises ActionController::ParameterMissing, which Rails
    # maps to a bare 400 with no body and no `public/400.html` to fill it. From
    # the client that is indistinguishable from the app falling over — and it is
    # exactly what an interrupted or unparseable multipart upload produces, i.e.
    # the case a logo upload actually hits. A missing key is a malformed
    # request, not a crash, so answer it the way every other rejection here is
    # answered: a status the client can read, with a reason attached.
    attrs  = params.fetch(:organisation, ActionController::Parameters.new)
                   .permit(:name, :logo, :remove_logo)
    remove = ActiveModel::Type::Boolean.new.cast(attrs.delete(:remove_logo))

    if attrs.empty? && !remove
      return respond_to_update(false, remove,
                               "We didn't receive the file — the upload may have been interrupted. Please try again.")
    end

    @organisation.logo.purge if remove
    ok = @organisation.update(attrs)
    respond_to_update(ok, remove,
                      @organisation.errors.full_messages.to_sentence.presence || "Could not update organisation.")
  end

  private

  def respond_to_update(ok, remove, error)
    respond_to do |format|
      format.html do
        if ok
          redirect_to organisation_memberships_path(@organisation),
                      notice: remove ? "Logo removed." : "Brand updated."
        else
          redirect_to organisation_memberships_path(@organisation), alert: error
        end
      end
      format.json do
        if ok
          logo_url = @organisation.logo.attached? ? helpers.rails_blob_path(@organisation.logo, only_path: true) : nil
          render json: { ok: true, logo_url: logo_url }
        else
          render json: { ok: false, error: error }, status: :unprocessable_entity
        end
      end
    end
  end
end
