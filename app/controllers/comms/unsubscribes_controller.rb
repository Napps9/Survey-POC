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
    @recipient = find_recipientish!
  end

  def create
    recipient = find_recipientish!

    if recipient.is_a?(EmailCampaignRecipient)
      unless recipient.unsubscribed_at.present?
        recipient.update_columns(unsubscribed_at: Time.current)
        EmailSuppression.record!(recipient.email, reason: "unsubscribe",
                                 user_id: recipient.user_id,
                                 source_campaign_id: recipient.email_campaign_id)
        EmailEvent.log!("unsubscribe", recipient: recipient)
      end
    else
      unless EmailSuppression.exists?(email: recipient.email)
        EmailSuppression.record!(recipient.email, reason: "unsubscribe", user_id: recipient.user_id)
        EmailEvent.log!("unsubscribe", automation_run: recipient)
      end
    end

    render :done
  end

  private

  # Campaign recipients and automation runs share the token contract (and
  # the #email/#token the pages need); either kind of mail lands here.
  def find_recipientish!
    EmailCampaignRecipient.find_by(token: params[:token]) ||
      EmailAutomationRun.find_by!(token: params[:token])
  end
end
