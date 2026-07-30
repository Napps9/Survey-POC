class RegistrationsController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation
  layout "fullscreen"
  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to new_registration_path, alert: "Try again later." }

  def new
    @user = User.new
  end

  def create
    @user = User.new(
      name:          params[:name].to_s.strip,
      email_address: params[:email_address].to_s.strip.downcase,
      password:      params[:password],
      password_confirmation: params[:password_confirmation]
    )

    org_name = params[:organisation_name].to_s.strip

    if org_name.blank?
      flash.now[:alert] = "Organisation name is required."
      return render :new, status: :unprocessable_entity
    end

    # Terms acceptance is recorded at the moment it's given (P0-8). Checked
    # before save so a refused signup never leaves an account behind whose
    # terms_accepted_at we'd have to guess at later.
    unless ActiveModel::Type::Boolean.new.cast(params[:accept_terms])
      flash.now[:alert] = t("registrations.terms_required")
      return render :new, status: :unprocessable_entity
    end
    @user.terms_accepted_at = Time.current

    unless @user.valid?
      flash.now[:alert] = @user.errors.full_messages.first
      return render :new, status: :unprocessable_entity
    end

    if params[:password] != params[:password_confirmation]
      flash.now[:alert] = "Passwords do not match."
      return render :new, status: :unprocessable_entity
    end

    ActiveRecord::Base.transaction do
      @user.save!
      slug = org_name.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
      slug = "#{slug}-#{SecureRandom.hex(3)}" if Organisation.exists?(slug: slug)
      org  = Organisation.create!(name: org_name, slug: slug)
      Membership.create!(user: @user, organisation: org, role: "admin")
    end

    # Outside the transaction: a mail failure must not roll back a created
    # account. EmailConfirmationsController.deliver swallows its own errors and
    # the banner offers a resend.
    EmailConfirmationsController.deliver(@user)

    start_new_session_for @user
    redirect_to root_path, notice: t("registrations.welcome_confirm", email: @user.email_address)
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first
    render :new, status: :unprocessable_entity
  end
end
