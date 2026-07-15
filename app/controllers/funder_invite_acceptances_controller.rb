class FunderInviteAcceptancesController < ApplicationController
  skip_before_action :require_authentication, only: [ :show, :accept ]
  skip_before_action :set_current_organisation, only: [ :show, :accept ]
  layout "fullscreen"

  before_action :load_invite
  before_action :resume_session_if_possible
  before_action :load_join_options

  def show
  end

  def accept
    if @invite.accepted?
      return redirect_to new_session_path, alert: t("funder_invites.already_used")
    end
    if @invite.expired?
      return redirect_to new_session_path, alert: t("funder_invites.expired")
    end

    if Current.user && params[:join_as_organisation_id].present?
      accept_as_signed_in
    elsif params[:mode] == "sign_in"
      sign_in_for_invite
    else
      accept_new_or_existing
    end
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first
    render :show, status: :unprocessable_entity
  end

  private

  # Signed-in user joins with one of their existing admin orgs. No password
  # reconfirmation — the active session already authenticates them.
  def accept_as_signed_in
    org_id     = params[:join_as_organisation_id].to_i
    membership = Current.user.memberships.admin.find_by(organisation_id: org_id)
    unless membership
      flash.now[:alert] = t("funder_invites.pick_org_error")
      return render :show, status: :unprocessable_entity
    end

    org = membership.organisation
    if org.id == @invite.funder.organisation_id
      flash.now[:alert] = t("funder_invites.cannot_join_own")
      return render :show, status: :unprocessable_entity
    end
    if @invite.funder.funder_memberships.exists?(organisation_id: org.id)
      return redirect_to funder_path(@invite.funder), notice: t("funder_invites.already_licensed", org: org.name, funder: @invite.funder.name)
    end

    ActiveRecord::Base.transaction do
      FunderMembership.assign!(funder: @invite.funder, organisation: org)
      @invite.update!(accepted_at: Time.current)
    end

    redirect_to funder_path(@invite.funder), notice: t("funder_invites.joined", org: org.name, funder: @invite.funder.name)
  end

  def accept_new_or_existing
    email         = (@invite.addressed_email || params[:email_address].to_s.strip.downcase)
    existing_user = email.present? ? User.find_by(email_address: email) : nil
    admin_org     = existing_user && existing_user.memberships.admin.first&.organisation

    if admin_org
      password = params[:password]
      unless password.present? && existing_user.authenticate(password)
        flash.now[:alert] = t("funder_invites.wrong_password")
        return render :show, status: :unprocessable_entity
      end
      if admin_org.id == @invite.funder.organisation_id
        flash.now[:alert] = t("funder_invites.cannot_join_own")
        return render :show, status: :unprocessable_entity
      end
      ActiveRecord::Base.transaction do
        FunderMembership.assign!(funder: @invite.funder, organisation: admin_org)
        @invite.update!(accepted_at: Time.current)
        start_new_session_for existing_user
      end
      redirect_to funder_path(@invite.funder), notice: t("funder_invites.joined", org: admin_org.name, funder: @invite.funder.name)
    else
      name     = params[:name].to_s.strip
      org_name = params[:organisation_name].to_s.strip.presence || t("funder_invites.default_org_name", name: name)
      password = params[:password]
      confirm  = params[:password_confirmation]

      if name.blank?
        flash.now[:alert] = t("funder_invites.name_required")
        return render :show, status: :unprocessable_entity
      end
      if email.blank?
        flash.now[:alert] = t("funder_invites.email_required")
        return render :show, status: :unprocessable_entity
      end
      if password.blank? || password != confirm
        flash.now[:alert] = t("funder_invites.password_mismatch")
        return render :show, status: :unprocessable_entity
      end

      ActiveRecord::Base.transaction do
        user = existing_user || User.create!(name: name, email_address: email, password: password)
        licensed_org = Organisation.create!(name: org_name, slug: Organisation.generate_unique_slug(org_name))
        licensed_org.memberships.create!(user: user, role: "admin")
        FunderMembership.assign!(funder: @invite.funder, organisation: licensed_org)
        @invite.update!(accepted_at: Time.current)
        start_new_session_for user
      end
      redirect_to funder_path(@invite.funder), notice: t("funder_invites.welcome", funder: @invite.funder.name)
    end
  end

  # Unauthenticated existing-account holder enters email + password. We sign
  # them in and bounce back to GET, where the signed-in picker takes over.
  def sign_in_for_invite
    email    = params[:email_address].to_s.strip.downcase
    password = params[:password].to_s

    if email.blank? || password.blank?
      flash.now[:alert] = t("funder_invites.sign_in_required")
      return render :show, status: :unprocessable_entity
    end

    user = User.authenticate_by(email_address: email, password: password)
    unless user
      flash.now[:alert] = t("funder_invites.sign_in_failed")
      return render :show, status: :unprocessable_entity
    end

    start_new_session_for user
    redirect_to funder_invite_path(@invite.token)
  end

  def resume_session_if_possible
    resume_session
  end

  # Surfaces which of the signed-in user's admin orgs could claim this seat.
  def load_join_options
    @signed_in_user = Current.user
    return unless @signed_in_user

    member_org_ids = @invite.funder.funder_memberships.pluck(:organisation_id)
    admin_orgs = @signed_in_user.memberships.admin.includes(:organisation).map(&:organisation)
    @joinable_orgs       = admin_orgs.reject { |o| o.id == @invite.funder.organisation_id || member_org_ids.include?(o.id) }
    @already_member_orgs = admin_orgs.select { |o| member_org_ids.include?(o.id) }
    @creator_admin_orgs  = admin_orgs.select { |o| o.id == @invite.funder.organisation_id }
  end

  def load_invite
    @invite = Invite.licensee.find_by(token: params[:token])
    unless @invite
      redirect_to new_session_path, alert: t("funder_invites.not_found")
    end
  end
end
