# Signing a returning respondent in with the password they chose at the end of
# a Verto.
#
# PlayerAuthentication's header used to say there was deliberately no sign-in
# form anywhere, because the only way in was a link from an inbox. That stopped
# being true on the owner's instruction (2026-09-10): the join block now takes
# a password, so somebody coming back on a different device needs a door.
#
# There is NO respondent password reset. Building one needs outbound mail, and
# the mail is the thing this change was made to stop depending on. #link is the
# recovery route instead — the emailed sign-in link, kept alive for exactly
# this, and reachable only by someone who knows the path. It is not linked from
# any page: it cannot work until SMTP is fixed, and offering a respondent a
# button that silently does nothing is the bug this whole thread started with.
class PlayerSessionsController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  allow_signed_out_players
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # A password field on a public page. Two counters, distinct names because
  # Rails keys the limit on [controller_path, name, ip] — the same reason
  # PlayerController and PlayerSignInsController name theirs.
  rate_limit to: 10, within: 5.minutes, only: :create, name: "player_pw_ip",
             with: -> { redirect_to new_player_session_path, alert: t("player_session.too_many") }
  rate_limit to: 5, within: 15.minutes, only: :link, name: "player_link_ip",
             with: -> { redirect_to new_player_session_path, alert: t("player_session.too_many") }

  def new
    redirect_to you_path if player_signed_in?
  end

  def create
    email  = params[:email_address].to_s.strip.downcase.first(Player::MAX_EMAIL)
    player = Player.find_by(email_address: email)

    # One message for "no such address" and for "wrong password". The join
    # endpoint had to give that distinction up to make signup work; a bare
    # sign-in form does not, so it keeps it.
    if player&.password_digest.present? && player.authenticate(params[:password].to_s)
      start_player_session_for(player)
      redirect_to you_path, notice: t("player_session.welcome")
    else
      flash.now[:alert] = t("player_session.failed")
      render :new, status: :unauthorized
    end
  end

  # The emailed link, for someone who has forgotten their password. Answers the
  # same way whichever it did — this endpoint has no signup to perform, so the
  # oracle discipline the join block lost is still affordable here.
  def link
    email  = params[:email_address].to_s.strip.downcase.first(Player::MAX_EMAIL)
    player = email.match?(URI::MailTo::EMAIL_REGEXP) ? Player.find_by(email_address: email) : nil

    if player && MailConfigCheck.deliverable?
      _record, raw = PlayerSignInLink.mint!(player: player)
      PlayerSignInMailer.sign_in(player, raw, nil).deliver_later
    end

    redirect_to new_player_session_path, notice: t("player_session.link_sent")
  rescue => e
    ErrorReporting.report("PlayerSessionsController#link", e)
    redirect_to new_player_session_path, notice: t("player_session.link_sent")
  end
end
