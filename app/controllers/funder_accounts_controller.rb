class FunderAccountsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!
  before_action :load_funder

  def new
  end

  # Creates the licensed org's User + Organisation + admin Membership +
  # FunderMembership up front (rather than via a pending Invite they must
  # accept), then emails them a link to set their own password.
  def create
    name     = params[:name].to_s.strip
    email    = params[:email_address].to_s.strip.downcase
    org_name = params[:organisation_name].to_s.strip

    if name.blank? || email.blank? || org_name.blank?
      flash.now[:alert] = t("funder_accounts.missing_fields")
      return render :new, status: :unprocessable_entity
    end
    if User.exists?(email_address: email)
      flash.now[:alert] = t("funder_accounts.email_taken", email: email)
      return render :new, status: :unprocessable_entity
    end
    unless @funder.seats_available?
      flash.now[:alert] = t("funders.no_seats_available")
      return render :new, status: :unprocessable_entity
    end

    user = nil
    ActiveRecord::Base.transaction do
      user = User.create!(
        name: name, email_address: email,
        password: SecureRandom.hex(32), password_pending: true
      )
      licensed_org = Organisation.create!(
        name: org_name, slug: Organisation.generate_unique_slug(org_name)
      )
      licensed_org.memberships.create!(user: user, role: "admin")
      FunderMembership.assign!(funder: @funder, organisation: licensed_org)
    end

    begin
      FunderAccountMailer.welcome(user, @funder).deliver_now
    rescue => e
      Rails.logger.error "[FunderAccountMailer] #{e.class}: #{e.message}"
      raise if Rails.env.development?
    end

    redirect_to funder_path(@funder), notice: t("funder_accounts.created", email: email)
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first
    render :new, status: :unprocessable_entity
  end

  private

  def load_funder
    @funder = current_organisation.funders.find(params[:funder_id])
  end
end
