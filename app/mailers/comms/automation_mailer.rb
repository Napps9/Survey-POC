# Delivers one automation firing. The compiled artifact lives on the
# automation (compile-on-save); personalization is the unsubscribe URL and
# the open pixel — no click wrapping (the links table is campaign-scoped;
# automation clicks are deliberately untracked in v1).
class Comms::AutomationMailer < ApplicationMailer
  def automation_email(run_id)
    run = EmailAutomationRun.find(run_id)
    automation = run.email_automation

    unsub = comms_unsubscribe_url(token: run.token)
    html = Comms::Personalizer.html(automation.compiled_html.to_s, unsubscribe_url: unsub,
                                                                   pixel_url: comms_open_url(token: run.token))
    text = Comms::Personalizer.text(automation.compiled_text.to_s, unsubscribe_url: unsub)

    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    headers["List-Unsubscribe"] = "<#{unsub}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"

    options = { to: run.email, subject: automation.subject }
    if automation.from_name.present?
      options[:from] = email_address_with_name(Comms.from_address, automation.from_name)
    end
    reply_to = automation.reply_to.presence || ENV["MAIL_REPLY_TO"].presence
    options[:reply_to] = reply_to if reply_to

    mail(**options) do |format|
      format.html { render html: html.html_safe }
      format.text { render plain: text }
    end
  end

  def test_email(automation_id, to)
    automation = EmailAutomation.find(automation_id)
    html = Comms::EmailRenderer.render_html(automation.document, preheader: automation.preheader,
                                                                 unsubscribe_url: "#")
    text = Comms::EmailRenderer.render_text(automation.document, unsubscribe_url: "#")

    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(to: to, subject: "[Test] #{automation.subject.presence || automation.name}") do |format|
      format.html { render html: html.html_safe }
      format.text { render plain: text }
    end
  end
end
