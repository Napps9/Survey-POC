class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  layout "fullscreen"
  skip_before_action :set_current_organisation
  # Two limits, because they stop different attacks (P1-12). The IP limit stops
  # one machine grinding through many accounts; the per-address limit stops a
  # rotating pool of IPs grinding through ONE account, which the IP limit alone
  # never sees. Both need explicit names once there is more than one.
  #
  # The IP limit is deliberately NOT lowered from 10, despite the plan
  # suggesting it: a whole office behind one NAT'd address is a normal shape for
  # this product, and the per-address limit is the precise fix for the case that
  # actually matters. Both counters only became real with P0-5 — on the old
  # per-process memory store they reset on every deploy.
  rate_limit to: 10, within: 3.minutes, only: :create, name: "ip",
             with: -> { redirect_to new_session_path, alert: "Try again later." }
  rate_limit to: 10, within: 20.minutes, only: :create, name: "email",
             by:   -> { "email:#{params[:email_address].to_s.strip.downcase}" },
             with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
