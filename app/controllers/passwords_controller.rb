class PasswordsController < ApplicationController
  allow_unauthenticated_access
  layout "fullscreen"
  skip_before_action :set_current_organisation
  before_action :set_user_by_token, only: %i[ edit update ]
  # Per-IP and per-address (P1-12). The second one matters twice over here: it
  # bounds reset attempts against one account, and it stops someone mail-bombing
  # a single inbox with reset links from a rotating pool of addresses.
  rate_limit to: 10, within: 3.minutes, only: :create, name: "ip",
             with: -> { redirect_to new_password_path, alert: "Try again later." }
  rate_limit to: 5, within: 20.minutes, only: :create, name: "email",
             by:   -> { "email:#{params[:email_address].to_s.strip.downcase}" },
             with: -> { redirect_to new_password_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address])
      begin
        PasswordsMailer.reset(user).deliver_now
      rescue => e
        ErrorReporting.report("PasswordsMailer", e)
        raise if Rails.env.development?
      end
    end

    redirect_to new_session_path, notice: "Password reset instructions sent (if user with that email address exists)."
  end

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.update!(password_pending: false) if @user.password_pending?
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: "Password has been reset. Sign in with your new password."
    else
      redirect_to edit_password_path(params[:token]),
        alert: @user.errors.full_messages.to_sentence.presence || "Passwords did not match."
    end
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
    end
end
