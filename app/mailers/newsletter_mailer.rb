# Tells the owner Thursday's draft is waiting, and what still needs doing to
# it. Internal mail to the Comms team only — no view files and no locale
# plumbing, in the shape of Comms::CampaignMailer.
#
# It exists because a draft nobody knows about is a draft that misses Monday.
class NewsletterMailer < ApplicationMailer
  def draft_ready(campaign, item_count: 0, source: nil)
    to = recipients
    return message.perform_deliveries = false if to.empty?

    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(to: to, subject: "Draft ready: #{campaign.title}") do |format|
      format.text { render plain: body_for(campaign, item_count, source) }
    end
  end

  private

  # The people who can actually open it: the Playverto org's members, the
  # same membership CommsAccess gates the whole suite on.
  def recipients
    org = Organisation.find_by(slug: CommsAccess::PLAYVERTO_SLUG)
    return [] if org.nil?

    User.where(id: org.memberships.select(:user_id)).where.not(email_verified_at: nil)
        .pluck(:email_address)
  end

  def body_for(campaign, item_count, source)
    audience_size = Comms::AudienceResolver.count(campaign.audience)
    edit_url = edit_comms_campaign_url(campaign)

    lines = []
    lines << "This week's newsletter draft is ready to review."
    lines << ""
    lines << "  #{campaign.title}"
    lines << "  Subject: #{campaign.subject}"
    lines << "  #{item_count} feature #{"item".pluralize(item_count)}#{" (written from commit subjects — Claude was unavailable)" if source == "fallback"}"
    lines << "  Audience: #{audience_size} #{"recipient".pluralize(audience_size)}"
    lines << ""
    lines << "Before you send it:"
    lines << "  - Fill in the Projects section (it's a placeholder right now)."
    lines << "  - Read the feature copy — it was drafted from this week's commits."
    if audience_size.zero?
      lines << "  - The audience is EMPTY, so the send will be refused. Add contacts"
      lines << "    to the '#{Comms::GenerateNewsletterJob::LIST_NAME}' list first."
    end
    lines << ""
    lines << "It is suggested for #{campaign.scheduled_for&.strftime("%A %-d %B, %H:%M")} — nothing sends until you book it."
    lines << ""
    lines << edit_url
    lines.join("\n")
  end
end
