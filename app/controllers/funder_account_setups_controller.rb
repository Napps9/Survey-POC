class FunderAccountSetupsController < ApplicationController
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
      redirect_to destination_path, notice: t("funder_account_setups.welcome")
    else
      redirect_to edit_funder_account_setup_path(params[:token]),
        alert: @user.errors.full_messages.to_sentence.presence || t("funder_account_setups.password_mismatch")
    end
  end

  private

  def set_user_by_token
    @user = User.find_by_token_for!(:account_setup, params[:token])
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_session_path, alert: t("funder_account_setups.invalid_link")
  end

  # The funder this owner-created account was set up for — its one org
  # membership points at the licensed org, which has exactly one funder
  # membership fresh out of FunderAccountsController#create.
  def destination_path
    membership = @user.memberships.first&.organisation&.funder_memberships
                       &.order(created_at: :desc)&.first
    membership ? funder_path(membership.funder) : root_path
  end
end
