class OrganisationsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!, only: [:edit, :update]

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
    attrs = params.require(:organisation).permit(:name, :logo, :remove_logo)
    remove = ActiveModel::Type::Boolean.new.cast(attrs.delete(:remove_logo))
    @organisation.logo.purge if remove
    ok = @organisation.update(attrs)
    error = @organisation.errors.full_messages.to_sentence.presence || "Could not update organisation."

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
