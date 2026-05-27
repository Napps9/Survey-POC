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
    current_organisation.invites.pending.where(email_address: email, kind: "member").update_all(expires_at: Time.current)

    @invite = current_organisation.invites.create!(
      email_address: email,
      role:          role,
      kind:          "member",
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

    if @invite.partner?
      accept_partner_invite
    else
      accept_member_invite
    end
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first
    render :show, status: :unprocessable_entity
  end

  private

  def accept_member_invite
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
  end

  def accept_partner_invite
    alliance = @invite.alliance
    unless alliance
      return redirect_to new_session_path, alert: "This invite is no longer valid."
    end

    email         = (@invite.addressed_email || params[:email_address].to_s.strip.downcase)
    existing_user = email.present? ? User.find_by(email_address: email) : nil
    admin_org     = existing_user && existing_user.memberships.admin.first&.organisation

    if admin_org
      password = params[:password]
      unless password.present? && existing_user.authenticate(password)
        flash.now[:alert] = "Enter your existing Playverto password to link your organisation."
        return render :show, status: :unprocessable_entity
      end
      if admin_org.id == alliance.organisation_id
        flash.now[:alert] = "You can't join an alliance you created."
        return render :show, status: :unprocessable_entity
      end
      ActiveRecord::Base.transaction do
        join_alliance(admin_org, alliance)
        @invite.update!(accepted_at: Time.current)
        start_new_session_for existing_user
      end
      redirect_to alliance_path(alliance), notice: "#{admin_org.name} joined #{alliance.name}."
    else
      name     = params[:name].to_s.strip
      org_name = params[:organisation_name].to_s.strip.presence || "#{name}'s organisation"
      password = params[:password]
      confirm  = params[:password_confirmation]

      if name.blank?
        flash.now[:alert] = "Name is required."
        return render :show, status: :unprocessable_entity
      end
      if email.blank?
        flash.now[:alert] = "Email is required."
        return render :show, status: :unprocessable_entity
      end
      if password.blank? || password != confirm
        flash.now[:alert] = "Passwords are required and must match."
        return render :show, status: :unprocessable_entity
      end

      ActiveRecord::Base.transaction do
        user = existing_user || User.create!(name: name, email_address: email, password: password)
        partner_org = Organisation.create!(
          name: org_name,
          slug: Organisation.generate_unique_slug(org_name)
        )
        partner_org.memberships.create!(user: user, role: "admin")
        join_alliance(partner_org, alliance)
        @invite.update!(accepted_at: Time.current)
        start_new_session_for user
      end
      redirect_to alliance_path(alliance), notice: "Welcome to #{alliance.name}!"
    end
  end

  def join_alliance(partner_org, alliance)
    AllianceMembership.find_or_create_by!(
      alliance: alliance,
      organisation: partner_org
    ) { |m| m.status = "active" }
    AllianceShareSync.ensure_shares_for(alliance: alliance)
  end

  def load_invite
    @invite = Invite.find_by(token: params[:token])
    unless @invite
      redirect_to new_session_path, alert: "Invite not found."
    end
  end
end
