# The two links at the foot of every mail we send a respondent.
#
# GET confirms and POST acts, for the reason Comms::UnsubscribesController
# splits the same way: corporate link scanners and inbox prefetchers follow
# GETs, and a scanner must not be able to opt a person out of anything. RFC
# 8058 one-click unsubscribes arrive as a POST straight from a mail client with
# no CSRF token, which is why forgery protection here is null_session rather
# than a skipped filter — the same precedent that controller cites.
#
# Two scopes, and offering both is the whole point (board H):
#
#   organisation — a new, narrow preference. Nothing in the app had one.
#   all          — today's EmailSuppression, unique on `email` and subtracted
#                  from every send in the product. It genuinely does mean
#                  "stop everything Playverto sends you", including a creator's
#                  own results digest if they happen to use this address — and
#                  creators play their own Vertos, so that is a matter of time.
#                  Which is exactly why the narrow one has to exist, and why
#                  this page says plainly which is which.
class PlayerUnsubscribesController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation
  layout "fullscreen"
  protect_from_forgery with: :null_session, only: [ :create ]

  # A bearer token in an inbox, so the same posture the sign-in link gets.
  rate_limit to: 20, within: 5.minutes, only: :create, name: "unsub_ip",
             with: -> { redirect_to you_path }

  before_action :find_notification

  def show
    # @notification may be nil — a deleted Verto or a purged account takes its
    # notifications with it. The page says the link has expired rather than
    # 404ing, because "I clicked unsubscribe and got an error" is the one
    # outcome guaranteed to produce a complaint.
  end

  def create
    return render :show, status: :unprocessable_entity if @notification.nil?

    if scope == "all"
      EmailSuppression.record!(@notification.player.email_address, reason: "unsubscribe")
    else
      PlayerEmailPreference.unsubscribe!(player: @notification.player,
                                         organisation: @notification.organisation)
    end

    @done = scope
    render :done
  end

  private

  def find_notification
    @notification = PlayerNotification.includes(:player, :organisation).find_by(token: params[:token])
  end

  # Anything that isn't an explicit "all" is the narrow one. A malformed or
  # missing scope must fail toward the SMALLER consequence — an unsubscribe
  # nobody meant to be global is a support ticket; a global one nobody meant
  # is a person silently cut off from a creator's mail as well.
  def scope
    params[:scope].to_s == "all" ? "all" : "organisation"
  end
end
