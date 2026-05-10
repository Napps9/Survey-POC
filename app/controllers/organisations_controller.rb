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

    if @organisation.update(attrs)
      redirect_to organisation_memberships_path(@organisation),
                  notice: remove ? "Logo removed." : "Brand updated."
    else
      redirect_to organisation_memberships_path(@organisation),
                  alert: @organisation.errors.full_messages.to_sentence.presence || "Could not update organisation."
    end
  end
end
