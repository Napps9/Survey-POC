class PartnershipAccountsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!
  before_action :load_partnership

  def new
  end

  # Creates the partner's User + Organisation + admin Membership +
  # PartnershipMembership up front (rather than via a pending Invite the
  # partner must accept), then emails them a link to set their own password.
  def create
    name     = params[:name].to_s.strip
    email    = params[:email_address].to_s.strip.downcase
    org_name = params[:organisation_name].to_s.strip

    if name.blank? || email.blank? || org_name.blank?
      flash.now[:alert] = t("partnership_accounts.missing_fields")
      return render :new, status: :unprocessable_entity
    end
    if User.exists?(email_address: email)
      flash.now[:alert] = t("partnership_accounts.email_taken", email: email)
      return render :new, status: :unprocessable_entity
    end

    user = nil
    ActiveRecord::Base.transaction do
      user = User.create!(
        name: name, email_address: email,
        password: SecureRandom.hex(32), password_pending: true
      )
      partner_org = Organisation.create!(
        name: org_name, slug: Organisation.generate_unique_slug(org_name)
      )
      partner_org.memberships.create!(user: user, role: "admin")
      PartnershipMembership.join!(partnership: @partnership, organisation: partner_org)
    end

    begin
      PartnershipAccountMailer.welcome(user, @partnership).deliver_now
    rescue => e
      ErrorReporting.report("PartnershipAccountMailer", e)
      raise if Rails.env.development?
    end

    redirect_to partnership_path(@partnership), notice: t("partnership_accounts.created", email: email)
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first
    render :new, status: :unprocessable_entity
  end

  private

  def load_partnership
    @partnership = current_organisation.partnerships.find(params[:partnership_id])
  end
end
