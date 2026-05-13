class AllianceInvitesController < ApplicationController
  layout "fullscreen"
  before_action :require_creator_org!
  before_action :require_admin!

  def new
  end

  def create
    email = params[:email_address].to_s.strip.downcase

    if email.blank?
      flash.now[:alert] = "Email address is required."
      return render :new, status: :unprocessable_entity
    end

    existing_user = User.find_by(email_address: email)
    if existing_user
      already_partner_org = existing_user.memberships.admin.map(&:organisation_id).any? do |org_id|
        current_organisation.alliances.exists?(partner_organisation_id: org_id)
      end
      if already_partner_org
        flash.now[:alert] = "#{email} is already a partner of this organisation."
        return render :new, status: :unprocessable_entity
      end
    end

    current_organisation.invites.pending.where(email_address: email, kind: "partner").update_all(expires_at: Time.current)

    @invite = current_organisation.invites.create!(
      email_address: email,
      role:          "admin",
      kind:          "partner",
      invited_by:    Current.user,
      expires_at:    14.days.from_now
    )
  end
end
