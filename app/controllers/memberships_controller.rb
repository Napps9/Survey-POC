class MembershipsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!

  def index
    @memberships = current_organisation.memberships.includes(:user).order("users.name")
  end

  def new
    @membership = Membership.new
  end

  def create
    email = params[:email_address].to_s.strip.downcase
    user  = User.find_by(email_address: email)

    unless user
      flash.now[:alert] = "No user found with that email address."
      @membership = Membership.new
      return render :new, status: :unprocessable_entity
    end

    if current_organisation.memberships.exists?(user: user)
      flash.now[:alert] = "That user is already a member of this organisation."
      @membership = Membership.new
      return render :new, status: :unprocessable_entity
    end

    current_organisation.memberships.create!(user: user, role: params[:role].presence || "member")
    redirect_to organisation_memberships_path(current_organisation), notice: "#{user.name} added."
  end

  def destroy
    membership = current_organisation.memberships.find(params[:id])
    if membership.user == Current.user
      redirect_to organisation_memberships_path(current_organisation), alert: "You cannot remove yourself."
    else
      membership.destroy
      redirect_to organisation_memberships_path(current_organisation), notice: "Member removed."
    end
  end
end
