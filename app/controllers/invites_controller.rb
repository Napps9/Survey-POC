class InvitesController < ApplicationController
  skip_before_action :require_authentication, only: [ :show, :accept ]
  skip_before_action :set_current_organisation, only: [ :show, :accept ]
  layout "fullscreen"

  before_action :require_admin!, only: [ :new, :create ]
  before_action :load_invite,    only: [ :show, :accept ]
  before_action :resume_session_if_possible, only: [ :show, :accept ]
  before_action :load_join_options, only: [ :show, :accept ]

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
      if Current.user && params[:join_as_organisation_id].present?
        accept_partner_invite_as_signed_in
      elsif params[:mode] == "sign_in"
        sign_in_for_partner_invite
      else
        accept_partner_invite
      end
    else
      accept_member_invite
    end
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first
    render :show, status: :unprocessable_entity
  end

  private

  def accept_member_invite
    existing_user = User.find_by(email_address: @invite.email_address)

    # Joining an *existing* account to the org must be authorised by its owner:
    # either they're already signed in as that user, or they enter its password.
    # Without this, anyone holding the invite link could be signed in as the
    # account matching the invite email (which the inviting admin chooses) — a
    # straightforward account takeover. New invitees set their password here as
    # they create the account.
    if existing_user
      unless Current.user == existing_user || authenticate_invitee(existing_user)
        flash.now[:alert] = "An account already exists for #{@invite.email_address}. Enter its password to join #{@invite.organisation.name}."
        return render :show, status: :unprocessable_entity
      end
      user = existing_user
    else
      name     = params[:name].to_s.strip
      password = params[:password]
      confirm  = params[:password_confirmation]

      if name.blank?
        flash.now[:alert] = "Name is required."
        return render :show, status: :unprocessable_entity
      end
      if password.blank? || password != confirm
        flash.now[:alert] = "Passwords are required and must match."
        return render :show, status: :unprocessable_entity
      end
      user = User.create!(name: name, email_address: @invite.email_address, password: password)
    end

    ActiveRecord::Base.transaction do
      unless @invite.organisation.memberships.exists?(user: user)
        @invite.organisation.memberships.create!(user: user, role: @invite.role)
      end
      @invite.update!(accepted_at: Time.current)
    end

    start_new_session_for(user) unless Current.user == user
    redirect_to root_path, notice: "Welcome to #{@invite.organisation.name}!"
  end

  # True when the accept form carries the existing account's correct password.
  def authenticate_invitee(user)
    password = params[:password].to_s
    password.present? && user.authenticate(password)
  end

  # Unauthenticated existing-account holder enters email + password. We sign
  # them in and bounce back to GET /invites/:token, where the signed-in
  # picker takes over.
  def sign_in_for_partner_invite
    email    = params[:email_address].to_s.strip.downcase
    password = params[:password].to_s

    if email.blank? || password.blank?
      flash.now[:alert] = "Enter your email and password to sign in."
      return render :show, status: :unprocessable_entity
    end

    user = User.authenticate_by(email_address: email, password: password)
    unless user
      flash.now[:alert] = "Couldn't find an account with that email and password."
      return render :show, status: :unprocessable_entity
    end

    start_new_session_for user
    redirect_to invite_path(@invite.token)
  end

  # Signed-in user joins the partnership with one of their existing admin orgs.
  # No password reconfirmation — the active session already authenticates them.
  def accept_partner_invite_as_signed_in
    partnership = @invite.partnership
    unless partnership
      return redirect_to new_session_path, alert: "This invite is no longer valid."
    end

    org_id     = params[:join_as_organisation_id].to_i
    membership = Current.user.memberships.admin.find_by(organisation_id: org_id)
    unless membership
      flash.now[:alert] = "Pick one of your organisations to join with."
      return render :show, status: :unprocessable_entity
    end

    org = membership.organisation
    if org.id == partnership.organisation_id
      flash.now[:alert] = "You can't join a partnership you created."
      return render :show, status: :unprocessable_entity
    end
    if partnership.partnership_memberships.exists?(organisation_id: org.id)
      return redirect_to partnership_path(partnership), notice: "#{org.name} is already a member of #{partnership.name}."
    end

    ActiveRecord::Base.transaction do
      join_partnership(org, partnership)
      @invite.update!(accepted_at: Time.current)
    end

    redirect_to partnership_path(partnership), notice: "#{org.name} joined #{partnership.name}."
  end

  def accept_partner_invite
    partnership = @invite.partnership
    unless partnership
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
      if admin_org.id == partnership.organisation_id
        flash.now[:alert] = "You can't join a partnership you created."
        return render :show, status: :unprocessable_entity
      end
      ActiveRecord::Base.transaction do
        join_partnership(admin_org, partnership)
        @invite.update!(accepted_at: Time.current)
        start_new_session_for existing_user
      end
      redirect_to partnership_path(partnership), notice: "#{admin_org.name} joined #{partnership.name}."
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
        join_partnership(partner_org, partnership)
        @invite.update!(accepted_at: Time.current)
        start_new_session_for user
      end
      redirect_to partnership_path(partnership), notice: "Welcome to #{partnership.name}!"
    end
  end

  def join_partnership(partner_org, partnership)
    PartnershipMembership.find_or_create_by!(
      partnership: partnership,
      organisation: partner_org
    ) { |m| m.status = "active" }
    PartnershipShareSync.ensure_shares_for(partnership: partnership)
  end

  # Populates Current.user if there's a valid session cookie. Used by the
  # invite-acceptance pages so signed-in users can join with an existing org
  # instead of being asked to re-enter credentials.
  def resume_session_if_possible
    resume_session
  end

  # For the partner-invite show/accept actions, surface which of the
  # signed-in user's admin orgs could join this partnership.
  def load_join_options
    @signed_in_user = Current.user
    return unless @signed_in_user && @invite&.partner?

    partnership = @invite.partnership
    return unless partnership

    member_org_ids = partnership.partnership_memberships.pluck(:organisation_id)
    admin_orgs = @signed_in_user.memberships.admin.includes(:organisation).map(&:organisation)
    @joinable_orgs       = admin_orgs.reject { |o| o.id == partnership.organisation_id || member_org_ids.include?(o.id) }
    @already_member_orgs = admin_orgs.select { |o| member_org_ids.include?(o.id) }
    @creator_admin_orgs  = admin_orgs.select { |o| o.id == partnership.organisation_id }
  end

  def load_invite
    @invite = Invite.find_by(token: params[:token])
    unless @invite
      redirect_to new_session_path, alert: "Invite not found."
    end
  end
end
