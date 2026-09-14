# The one page between the end of a Verto and Google.
#
# It exists for a single reason, and the reason is the service worker. OmniAuth
# 2.x makes the request phase a CSRF-protected POST
# (omniauth-rails_csrf_protection), and `/play/:token` — the page the Continue
# with Google button lives on — is inside the worker's scope and can be served
# from cache with an authenticity token of any age. That is the same fact that
# put #join under `protect_from_forgery with: :null_session`. A POST straight
# from the card would therefore fail for exactly the people whose connection
# made the cache do its job.
#
# So the card hands its claims to PlayerController#join_google, which parks
# them on a PlayerOauthHandoff and answers with this page's URL. `/you/…` is
# outside the worker's scope, so this page is always fetched, and its token is
# live.
#
# It does NOT auto-submit. Bouncing straight to Google would mean the browser's
# Back button lands here and immediately throws them forward again, which is a
# trap rather than a convenience — and a GET that starts a redirect the moment
# a link scanner touches it is the pattern PlayerSignInsController's header
# exists to argue against.
#
# Nothing is spent here. The handoff is consumed by the callback, once Google
# has actually said who this is; a person who opens this page and changes their
# mind has lost nothing but the tab.
class PlayerJoinsController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  allow_signed_out_players
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # The token is a bearer credential; bound what one IP may try. Distinct name
  # because Rails keys the counter on [controller_path, name, ip].
  rate_limit to: 30, within: 5.minutes, name: "player_join_ip",
             with: -> { redirect_to you_path, alert: t("player_sign_in.too_many") }

  def show
    return redirect_to you_path if player_signed_in?

    @handoff = PlayerOauthHandoff.find_live(params[:token])
    # Remember it as an id, not as the token: the callback re-checks liveness
    # and spends it atomically, so all this has to carry across the round trip
    # is which row — and a bearer token that never enters the cookie is one
    # that cannot leak out of it.
    session[:player_oauth_handoff_id] = @handoff&.id

    # @handoff may be nil, and the view says so rather than 404ing — "this
    # expired while you were deciding" is the likeliest reason to be here
    # without one, and it is worth saying plainly. The provider list is empty
    # when Google isn't configured, and the view degrades to the same page.
    @providers = SocialAuth.player_enabled
    @survey = @handoff&.survey
  end
end
