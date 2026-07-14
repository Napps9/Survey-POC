class PartnerAccountSetupsController < ApplicationController
  allow_unauthenticated_access
  layout "fullscreen"
  skip_before_action :set_current_organisation
  before_action :set_user_by_token, only: %i[ edit update ]

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.update!(password_pending: false)
      start_new_session_for(@user)
      redirect_to destination_path, notice: t("partner_account_setups.welcome")
    else
      redirect_to edit_partner_account_setup_path(params[:token]),
        alert: @user.errors.full_messages.to_sentence.presence || t("partner_account_setups.password_mismatch")
    end
  end

  private

  def set_user_by_token
    @user = User.find_by_token_for!(:account_setup, params[:token])
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_session_path, alert: t("partner_account_setups.invalid_link")
  end

  # The partnership this owner-created account was set up for — its one org
  # membership points at the partner org, which is a member of exactly one
  # partnership fresh out of PartnershipAccountsController#create.
  def destination_path
    partnership = @user.memberships.first&.organisation&.member_partnerships
                        &.order(created_at: :desc)&.first
    partnership ? partnership_path(partnership) : root_path
  end
end
