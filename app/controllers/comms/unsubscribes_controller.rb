# The recipient-facing unsubscribe flow. GET renders a confirm page rather
# than acting — corporate link scanners and inbox prefetchers follow GETs,
# and a scanner must not be able to opt a person out. POST records the
# opt-out; RFC 8058 one-click unsubscribes land here as a POST too, which is
# why forgery protection is null_session (the player_controller precedent)
# rather than a skipped filter: mail clients don't carry CSRF tokens.
class Comms::UnsubscribesController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation
  protect_from_forgery with: :null_session, only: [ :create ]

  def show
    @recipient = EmailCampaignRecipient.find_by!(token: params[:token])
  end

  def create
    recipient = EmailCampaignRecipient.find_by!(token: params[:token])

    already = recipient.unsubscribed_at.present?
    unless already
      recipient.update_columns(unsubscribed_at: Time.current)
      EmailSuppression.record!(recipient.email, reason: "unsubscribe",
                               user_id: recipient.user_id,
                               source_campaign_id: recipient.email_campaign_id)
      EmailEvent.log!("unsubscribe", recipient: recipient)
    end

    render :done
  end
end
