# The link from the sign-in email, and the only way into a respondent account.
#
# GET renders a confirm page and consumes nothing; POST does the work. That
# split is not ceremony — corporate link scanners and inbox prefetchers follow
# GETs, and a single-use link that a scanner can spend is a link the person it
# was sent to can never use. Comms::UnsubscribesController splits for the same
# reason.
#
# The POST keeps ordinary CSRF protection rather than the null_session that
# controller uses. Unsubscribe needs null_session because RFC 8058 one-click
# POSTs arrive straight from mail clients with no token; this one comes from a
# form on a page Rails has just rendered. It matters: under null_session a
# failed check swaps in a cookie jar whose write is a no-op, so the link would
# be spent and the session silently never set.
class PlayerSignInsController < ApplicationController
  include PlayerAuthentication

  allow_unauthenticated_access
  allow_signed_out_players
  skip_before_action :set_current_organisation
  layout "fullscreen"

  # A link is a bearer credential, and the address it was sent to is the only
  # thing bounding who can try one. Distinct names because Rails keys the
  # counter on [controller_path, name, ip] — see PlayerController's comment.
  rate_limit to: 20, within: 5.minutes, only: :create, name: "signin_ip",
             with: -> { redirect_to you_path, alert: t("player_sign_in.too_many") }

  before_action :find_link

  def show
    # Nothing happens here. @link may be nil — the page says so rather than
    # 404ing, because "this link has already been used" is the single most
    # likely reason someone lands here and is worth saying plainly.
  end

  def create
    return render :show, status: :unprocessable_entity if @link.nil?
    # Single use, atomically: two taps race here and exactly one wins.
    return render :show, status: :unprocessable_entity unless @link.consume!

    player = @link.player
    player.verify_email!
    apply_claims(player, @link.claim_payload)
    start_player_session_for(player)

    redirect_to you_path, notice: t("player_sign_in.welcome")
  end

  private

  def find_link
    @link = PlayerSignInLink.find_live(params[:token])
  end

  # The Vertos this link was minted to attach. Written here rather than when
  # the address was typed, so nothing is ever recorded against an address until
  # someone proves they can read it.
  #
  # Every step is defensive: a response may have been erased between the join
  # and the click, and a survey may have been deleted. A claim that cannot be
  # made is skipped, never raised — the person is signing in, and the sign-in
  # must not fail because one of their Vertos went away.
  def apply_claims(player, payload)
    Array(payload).each do |entry|
      next unless entry.is_a?(Hash)

      response = Response.find_by(id: entry["response_id"])
      next if response.nil?

      source = PlayerClaim::SOURCES.include?(entry["source"]) ? entry["source"] : "signup"
      PlayerClaim.claim!(player: player, response: response, source: source)
    end
  rescue => e
    # A partial claim is better than a failed sign-in: they are in, and the
    # missing Verto is recoverable by playing it again.
    ErrorReporting.report("PlayerSignInsController#apply_claims", e, player_id: player.id)
  end
end
