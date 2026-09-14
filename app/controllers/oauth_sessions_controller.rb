class OauthSessionsController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation

  def create
    # A respondent must never be minted a creator account and a workspace. The
    # route above this one in config/routes.rb already sends them elsewhere;
    # this is the guard that makes reordering those two lines a visible failure
    # rather than a silent one, because the damage would otherwise be a real
    # account somebody has to go and delete.
    return failure if SocialAuth.player_strategy?(params[:provider])

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

  # OmniAuth routes every strategy's failure through one path, so this is the
  # one place both populations land. A respondent who declined the consent
  # screen must go back to THEIR door: /session/new is the creator's, and
  # someone who got here from the end of a Verto has never seen it and cannot
  # use it. `strategy` is set by OmniAuth itself from the middleware, not by
  # the browser.
  def failure
    strategy = (params[:provider] || params[:strategy]).to_s
    back = SocialAuth.player_strategy?(strategy) ? new_player_session_path : new_session_path

    redirect_to back, alert: t("auth.social_failed", provider: SocialAuth.label_for(strategy))
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
