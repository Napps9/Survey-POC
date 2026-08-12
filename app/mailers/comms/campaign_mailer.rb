# Delivers one frozen campaign message to one recipient. Everything that
# decides content was frozen at approval (compiled_html/compiled_text +
# scheduled_snapshot); this mailer only personalizes: the recipient's
# unsubscribe URL first, then link tokens, then the open pixel. No view
# files — the artifact is already HTML.
class Comms::CampaignMailer < ApplicationMailer
  def campaign(recipient_id)
    recipient = EmailCampaignRecipient.find(recipient_id)
    c = recipient.email_campaign
    snapshot = c.scheduled_snapshot || {}

    unsub = comms_unsubscribe_url(token: recipient.token)
    links = c.email_campaign_links.pluck(:id).index_with do |id|
      comms_click_url(token: recipient.token, link_id: id)
    end
    html = Comms::Personalizer.html(c.compiled_html.to_s, unsubscribe_url: unsub, links: links,
                                                          pixel_url: comms_open_url(token: recipient.token))
    text = Comms::Personalizer.text(c.compiled_text.to_s, unsubscribe_url: unsub)

    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    headers["List-Unsubscribe"] = "<#{unsub}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"

    options = { to: recipient.email, subject: subject_for(snapshot, recipient.subject_variant) }
    if snapshot["from_name"].present?
      options[:from] = email_address_with_name(Comms.from_address, snapshot["from_name"])
    end
    reply_to = snapshot["reply_to"].presence || ENV["MAIL_REPLY_TO"].presence
    options[:reply_to] = reply_to if reply_to

    mail(**options) do |format|
      format.html { render html: html.html_safe }
      format.text { render plain: text }
    end
  end

  # A one-off proof to the author's own inbox: the CURRENT document (not a
  # frozen copy — there may be none yet), unsubscribe stubbed, nothing
  # tracked.
  def test_email(campaign_id, to)
    c = EmailCampaign.find(campaign_id)
    html = Comms::EmailRenderer.render_html(c.document, preheader: c.preheader, unsubscribe_url: "#")
    text = Comms::EmailRenderer.render_text(c.document, unsubscribe_url: "#")

    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(to: to, subject: "[Test] #{c.subject.presence || c.title}") do |format|
      format.html { render html: html.html_safe }
      format.text { render plain: text }
    end
  end

  private

  def subject_for(snapshot, variant)
    return snapshot["subject"].to_s if variant.to_i.zero?

    Array(snapshot["subject_variants"])[variant.to_i - 1].presence || snapshot["subject"].to_s
  end
end
