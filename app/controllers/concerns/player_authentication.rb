# Sign-in for RESPONDENTS, kept entirely apart from the creator's.
#
# Not a variant of Authentication and not a role on it: Current#user delegates
# to Current.session, and OrganisationScope#set_current_organisation
# dereferences Current.user.memberships with no nil guard, so a Player
# arriving through the creator's session would NoMethodError on its first
# request. Separate cookie, separate table, separate Current attribute.
#
# There is deliberately no sign-in FORM anywhere. The only way in is a link
# emailed from the end of a Verto, which is why this concern has no equivalent
# of request_authentication: a signed-out visitor is shown what /you is for,
# not sent to a page they cannot use.
module PlayerAuthentication
  extend ActiveSupport::Concern

  included do
    # Resuming and REQUIRING are two callbacks, not one, and that split is
    # load-bearing: /you#show is the page a signed-OUT visitor is allowed to
    # see, so it skips require_player — and if resuming lived inside that
    # method, skipping it would mean a signed-in respondent's cookie was never
    # read and they'd be shown the signed-out page on the one page that matters.
    #
    # Prepended so it runs ahead of ApplicationController's switch_locale,
    # which reads Current.player&.preferred_locale: registered normally it
    # would land after the around_action and the account's own language would
    # miss by one request.
    prepend_before_action :resume_player_session
    before_action :require_player
    helper_method :current_player, :player_signed_in?

    # Respondents, not creators. ApplicationController's `:modern` floor would
    # serve a 406 "browser not supported" page to exactly the population
    # PlayerController overrides it for — people on phones that stopped getting
    # updates. Same override, same reason (player_controller.rb:832).
    def allow_browser(versions:, block:)
      super(versions: PlayerController::PLAYER_BROWSER_VERSIONS, block: block)
    end
  end

  class_methods do
    def allow_signed_out_players(**options)
      skip_before_action :require_player, **options
    end
  end

  private

  def current_player = Current.player
  def player_signed_in? = Current.player.present?

  def require_player
    redirect_to(you_path) unless player_signed_in?
  end

  # Never halts the chain — a nil return from a before_action is just "no
  # player", which is a legitimate state on every page this concern is used on.
  def resume_player_session
    Current.player_session ||= find_player_session_by_cookie
    nil
  end

  def find_player_session_by_cookie
    return nil if cookies.signed[:player_session_id].blank?

    PlayerSession.find_by(id: cookies.signed[:player_session_id])
  end

  # Deliberately NOT a copy of Authentication#start_new_session_for. That method
  # calls reset_session because creator sign-in is a privilege boundary inside
  # the creator's own session; a player session is not in that chain, and
  # resetting here would wipe session[:current_organisation_id] for a creator
  # who clicks a player link to see their own Verto's end screen.
  def start_player_session_for(player)
    player.player_sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |ps|
      Current.player_session = ps
      cookies.signed.permanent[:player_session_id] = {
        value: ps.id, httponly: true, same_site: :lax
      }
    end
  end

  def terminate_player_session
    Current.player_session&.destroy
    Current.player_session = nil
    cookies.delete(:player_session_id)
  end
end
