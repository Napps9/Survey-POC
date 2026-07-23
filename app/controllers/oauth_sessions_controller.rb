class OauthSessionsController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation

  def create
    auth = request.env["omniauth.auth"]
    return failure unless auth

    user = locate_or_create_user!(auth)
    start_new_session_for user
    redirect_to after_authentication_url
  rescue MissingEmail
    redirect_to new_session_path,
                alert: t("auth.social_no_email", provider: SocialAuth.label_for(params[:provider]))
  rescue => e
    ErrorReporting.report("OauthSessions", e)
    failure
  end

  def failure
    redirect_to new_session_path,
                alert: t("auth.social_failed", provider: SocialAuth.label_for(params[:provider] || params[:strategy]))
  end

  private

  class MissingEmail < StandardError; end

  # Identity (provider+uid) is the canonical key. A new identity links to an
  # existing account when the emails match — only honoured when Google
  # asserts the address is verified, so a spoofed address can't take over an
  # account. Otherwise it's a brand-new sign-up: user + their own workspace.
  def locate_or_create_user!(auth)
    identity = Identity.find_or_initialize_by(provider: auth.provider.to_s, uid: auth.uid.to_s)
    email    = auth.info&.email.to_s.strip.downcase.presence
    email    = nil if auth.extra&.raw_info&.email_verified == false

    user = identity.user
    user ||= User.find_by(email_address: email) if email
    if user.nil?
      raise MissingEmail unless email
      user = create_user_with_workspace!(email, auth.info&.name.to_s.strip.presence)
    end

    identity.update!(user: user, email: email, name: auth.info&.name.to_s.strip.presence)
    user
  end

  # Mirrors RegistrationsController: every account belongs to an organisation
  # they administer. OAuth signups get a personal workspace they can rename
  # (no password is asked for — has_secure_password still needs one, so a
  # random throwaway is set; "forgot password" can mint a real one later).
  def create_user_with_workspace!(email, name)
    name ||= email.split("@").first.tr(".", " ").titleize
    ActiveRecord::Base.transaction do
      user = User.create!(name: name, email_address: email, password: SecureRandom.base58(24))
      org_name = "#{name.split.first}'s workspace"
      slug = org_name.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
      slug = "#{slug}-#{SecureRandom.hex(3)}" if Organisation.exists?(slug: slug)
      org  = Organisation.create!(name: org_name, slug: slug)
      Membership.create!(user: user, organisation: org, role: "admin")
      user
    end
  end
end
