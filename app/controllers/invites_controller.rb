class InvitesController < ApplicationController
  skip_before_action :require_authentication, only: [:show, :accept]
  skip_before_action :set_current_organisation, only: [:show, :accept]
  layout "fullscreen"

  before_action :require_admin!, only: [:new, :create]
  before_action :load_invite,    only: [:show, :accept]

  def new
  end

  def create
    email = params[:email_address].to_s.strip.downcase
    role  = params[:role].presence_in(%w[member admin]) || "member"

    if email.blank?
      flash.now[:alert] = "Email address is required."
      return render :new, status: :unprocessable_entity
    end

    existing = User.find_by(email_address: email)
    if existing && current_organisation.memberships.exists?(user: existing)
      flash.now[:alert] = "#{email} is already a member of this organisation."
      return render :new, status: :unprocessable_entity
    end

    # Expire any previous pending invite for this email in this org
    current_organisation.invites.pending.where(email_address: email).update_all(expires_at: Time.current)

    @invite = current_organisation.invites.create!(
      email_address: email,
      role:          role,
      invited_by:    Current.user,
      expires_at:    7.days.from_now
    )
  end

  def show
  end

  def accept
    if @invite.accepted?
      return redirect_to new_session_path, alert: "This invite link has already been used."
    end
    if @invite.expired?
      return redirect_to new_session_path, alert: "This invite has expired. Ask your admin to resend it."
    end

    name     = params[:name].to_s.strip
    password = params[:password]
    confirm  = params[:password_confirmation]

    if name.blank?
      flash.now[:alert] = "Name is required."
      return render :show, status: :unprocessable_entity
    end
    if password != confirm
      flash.now[:alert] = "Passwords do not match."
      return render :show, status: :unprocessable_entity
    end

    ActiveRecord::Base.transaction do
      user = User.find_by(email_address: @invite.email_address) ||
             User.create!(name: name, email_address: @invite.email_address, password: password)

      unless @invite.organisation.memberships.exists?(user: user)
        @invite.organisation.memberships.create!(user: user, role: @invite.role)
      end

      @invite.update!(accepted_at: Time.current)
      start_new_session_for user
    end

    redirect_to root_path, notice: "Welcome to #{@invite.organisation.name}!"
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first
    render :show, status: :unprocessable_entity
  end

  private

  def load_invite
    @invite = Invite.find_by(token: params[:token])
    unless @invite
      redirect_to new_session_path, alert: "Invite not found."
    end
  end
end
