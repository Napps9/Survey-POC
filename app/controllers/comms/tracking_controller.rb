# Public engagement endpoints for Comms mail: the 1×1 open pixel and the
# click redirect. Recipients are not platform users, so these sit outside
# every auth gate; identity is the recipient's random token and nothing
# else. Unknown tokens 404 — there is nothing to learn here.
class Comms::TrackingController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :set_current_organisation

  # A transparent 1×1 GIF, decoded once.
  PIXEL = Base64.decode64("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7").freeze

  def open
    recipient = EmailCampaignRecipient.find_by(token: params[:token])
    return head :not_found unless recipient

    recipient.record_open!
    EmailEvent.log!("open", recipient: recipient)

    response.headers["Cache-Control"] = "no-store"
    send_data PIXEL, type: "image/gif", disposition: "inline"
  end

  def click
    recipient = EmailCampaignRecipient.find_by(token: params[:token])
    return head :not_found unless recipient

    # Scoped to the recipient's own campaign: a link id from another
    # campaign is a 404, not a redirect.
    link = EmailCampaignLink.find_by(id: params[:link_id],
                                     email_campaign_id: recipient.email_campaign_id)
    return head :not_found unless link&.url&.match?(%r{\Ahttps?://}i)

    recipient.record_click!
    EmailEvent.log!("click", recipient: recipient, url: link.url)

    # The destination was stored by the campaign author at freeze time and
    # looked up by id above — nothing request-supplied is redirected to.
    redirect_to link.url, allow_other_host: true
  end
end
