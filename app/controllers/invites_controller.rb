class InvitesController < ApplicationController
  skip_before_action :require_authentication, only: [ :show, :accept ]
  skip_before_action :set_current_organisation, only: [ :show, :accept ]
  layout "fullscreen"

  # #accept verifies a password (User.authenticate_by, for an existing-account
  # holder following an invite link) and had NO rate limit at all — an
  # unauthenticated password oracle against ANY address, since the email is
  # taken from the form rather than from the invite (P1-12).
  #
  # Per-IP only, deliberately. This one action multiplexes several flows —
  # creating an account, joining as an already-signed-in user, signing in — and
  # a per-address limit would bucket every password-less request under one blank
  # key, throttling legitimate signed-in joins. The IP bound is what closes the
  # oracle; the precise per-address limits live on the dedicated sign-in and
  # reset endpoints where the action means exactly one thing.
  rate_limit to: 20, within: 3.minutes, only: :accept,
             with: -> { redirect_to invite_path(params[:token]), alert: t("flash.invites.rate_limited") }

  before_action :require_admin!, only: [ :new, :create ]
  before_action :load_invite,    only: [ :show, :accept ]
  before_action :resume_session_if_possible, only: [ :show, :accept ]
  before_action :load_join_options, only: [ :show, :accept ]

  def new
  end

  def create
    email = params[:email_address].to_s.strip.downcase
    role  = params[:role].presence_in(Membership::ROLES) || "member"

    if email.blank?
      flash.now[:alert] = t("flash.invites.email_address_required")
      return render :new, status: :unprocessable_entity
    end

    existing = User.find_by(email_address: email)
    if existing && current_organisation.memberships.exists?(user: existing)
      flash.now[:alert] = t("flash.invites.already_member", email: email)
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
      return redirect_to new_session_path, alert: t("flash.invites.already_used")
    end
    if @invite.expired?
      return redirect_to new_session_path, alert: t("flash.invites.expired")
    end

    if @invite.partner?
      if Current.user && params[:join_as_organisation_id].present?
        accept_partner_invite_as_signed_in
      elsif params[:mode] == "sign_in"
        sign_in_for_partner_invite
      else
        accept_partner_invite
      end
    elsif @invite.member?
      accept_member_invite
    else
      # Defence in depth: only member/partner invites are redeemable here.
      # (licensee is already redirected in load_invite.) Never fall a non-member
      # invite through to accept_member_invite, which would grant its role in the
      # invite's organisation.
      redirect_to new_session_path, alert: t("flash.invites.not_redeemable_here")
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
        flash.now[:alert] = t("flash.invites.account_exists_password_required", email: @invite.email_address, org: @invite.organisation.name)
        return render :show, status: :unprocessable_entity
      end
      user = existing_user
    else
      name     = params[:name].to_s.strip
      password = params[:password]
      confirm  = params[:password_confirmation]

      if name.blank?
        flash.now[:alert] = t("flash.invites.name_required")
        return render :show, status: :unprocessable_entity
      end
      if password.blank? || password != confirm
        flash.now[:alert] = t("flash.invites.password_mismatch")
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
    redirect_to root_path, notice: t("flash.invites.welcome_to_organisation", org: @invite.organisation.name)
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
      flash.now[:alert] = t("flash.invites.sign_in_required")
      return render :show, status: :unprocessable_entity
    end

    user = User.authenticate_by(email_address: email, password: password)
    unless user
      flash.now[:alert] = t("flash.invites.sign_in_failed")
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
      return redirect_to new_session_path, alert: t("flash.invites.invite_no_longer_valid")
    end

    org_id     = params[:join_as_organisation_id].to_i
    membership = Current.user.memberships.admin.find_by(organisation_id: org_id)
    unless membership
      flash.now[:alert] = t("flash.invites.pick_org_required")
      return render :show, status: :unprocessable_entity
    end

    org = membership.organisation
    if org.id == partnership.organisation_id
      flash.now[:alert] = t("flash.invites.cannot_join_own_partnership")
      return render :show, status: :unprocessable_entity
    end
    if partnership.partnership_memberships.exists?(organisation_id: org.id)
      return redirect_to partnership_path(partnership), notice: t("flash.invites.already_partnership_member", org: org.name, partnership: partnership.name)
    end

    ActiveRecord::Base.transaction do
      join_partnership(org, partnership)
      @invite.update!(accepted_at: Time.current)
    end

    redirect_to partnership_path(partnership), notice: t("flash.invites.joined_partnership", org: org.name, partnership: partnership.name)
  end

  def accept_partner_invite
    partnership = @invite.partnership
    unless partnership
      return redirect_to new_session_path, alert: t("flash.invites.invite_no_longer_valid")
    end

    email         = (@invite.addressed_email || params[:email_address].to_s.strip.downcase)
    existing_user = email.present? ? User.find_by(email_address: email) : nil
    admin_org     = existing_user && existing_user.memberships.admin.first&.organisation

    if admin_org
      password = params[:password]
      unless password.present? && existing_user.authenticate(password)
        flash.now[:alert] = t("flash.invites.existing_password_required")
        return render :show, status: :unprocessable_entity
      end
      if admin_org.id == partnership.organisation_id
        flash.now[:alert] = t("flash.invites.cannot_join_own_partnership")
        return render :show, status: :unprocessable_entity
      end
      ActiveRecord::Base.transaction do
        join_partnership(admin_org, partnership)
        @invite.update!(accepted_at: Time.current)
        start_new_session_for existing_user
      end
      redirect_to partnership_path(partnership), notice: t("flash.invites.joined_partnership", org: admin_org.name, partnership: partnership.name)
    else
      name     = params[:name].to_s.strip
      org_name = params[:organisation_name].to_s.strip.presence || "#{name}'s organisation"
      password = params[:password]
      confirm  = params[:password_confirmation]

      if name.blank?
        flash.now[:alert] = t("flash.invites.name_required")
        return render :show, status: :unprocessable_entity
      end
      if email.blank?
        flash.now[:alert] = t("flash.invites.email_required")
        return render :show, status: :unprocessable_entity
      end
      if password.blank? || password != confirm
        flash.now[:alert] = t("flash.invites.password_mismatch")
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
      redirect_to partnership_path(partnership), notice: t("flash.invites.welcome_to_partnership", partnership: partnership.name)
    end
  end

  def join_partnership(partner_org, partnership)
    PartnershipMembership.join!(partnership: partnership, organisation: partner_org)
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
      redirect_to new_session_path, alert: t("flash.invites.not_found") and return
    end
    # Licensee (funder) invites are ADMIN invites into the funder-owner's own
    # organisation and must ONLY be redeemed through the funder-acceptance flow
    # (which scopes them and assigns a licensee seat, not org admin). Redeeming
    # one here would drop the holder straight into accept_member_invite and mint
    # an admin membership in the owner's org — a full takeover. Send them to the
    # correct flow instead.
    if @invite.licensee?
      redirect_to funder_invite_path(@invite.token)
    end
  end
end
