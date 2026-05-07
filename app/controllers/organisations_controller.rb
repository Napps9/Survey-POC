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
    if @organisation.update(params.require(:organisation).permit(:name))
      redirect_to edit_organisation_path(@organisation), notice: "Organisation updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end
end
