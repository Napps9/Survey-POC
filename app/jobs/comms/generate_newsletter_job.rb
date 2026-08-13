# Thursday's newsletter draft.
#
# THIS JOB NEVER SENDS. It writes a `draft` campaign and stops: it does not
# freeze, and it does not enqueue StartCampaignSendJob. The owner reviews the
# draft, fills in the Projects section and books it for Monday themselves.
# The suggested Monday time is parked on the draft's scheduled_for, which is
# inert while the status is draft — Comms::SweepJob's due-campaign pass is
# scoped to `status: "scheduled"`.
#
# Whatever goes wrong upstream, Thursday still produces something reviewable:
# GitHub unreachable or a quiet week means no feature items, and a missing
# ANTHROPIC_API_KEY or a failed Claude call falls back to commit subjects.
class Comms::GenerateNewsletterJob < ApplicationJob
  queue_as :default

  # No retries, same reasoning as BuildVertoJob: a retried Claude call bills
  # twice, and a missed week is recoverable by hand.
  discard_on StandardError do |job, error|
    ErrorReporting.report("Comms::GenerateNewsletterJob", error, args: job.arguments)
  end

  LIST_NAME = ENV.fetch("NEWSLETTER_LIST_NAME", "Early adopters").freeze

  def perform(today = Date.current)
    week = Comms::NewsletterSource.week_of(today)
    return if EmailCampaign.exists?(newsletter_week: week)

    commits = Comms::NewsletterSource.digest(
      Comms::GithubCommits.since(week.to_time(:utc))
    )
    copy = NewsletterWriter.new.call(commits, week: week) ||
           Comms::NewsletterSource.fallback_copy(commits, week)

    list = EmailList.find_or_create_by!(name: LIST_NAME)
    campaign = create_campaign(copy, week: week, list: list, today: today)
    return if campaign.nil?

    NewsletterMailer.draft_ready(campaign, item_count: Array(copy["items"]).size,
                                           source: copy["source"]).deliver_later
  end

  private

  def create_campaign(copy, week:, list:, today:)
    EmailCampaign.create!(
      title:            "Newsletter — week of #{week.strftime("%-d %B %Y")}",
      subject:          copy["subject"],
      subject_variants: Array(copy["subject_variants"]),
      preheader:        copy["preheader"],
      from_name:       ENV.fetch("NEWSLETTER_FROM_NAME", "Playverto"),
      design:          Comms::NewsletterDocument.build(copy, brand: playverto_brand),
      audience:        { "kind" => "list", "list_id" => list.id },
      newsletter_week: week,
      scheduled_for:   suggested_send_at(today),
      status:          "draft"
    )
  rescue ActiveRecord::RecordNotUnique
    # Two runs raced for the same week; the other one won.
    nil
  end

  # The Monday after this run, 09:00 in the Comms timezone.
  def suggested_send_at(today)
    zone = ActiveSupport::TimeZone[ENV.fetch("COMMS_TIME_ZONE", "UTC")] || Time.zone
    zone.parse("#{Comms::NewsletterSource.next_monday(today)} 09:00")
  end

  def playverto_brand
    Organisation.find_by(slug: CommsAccess::PLAYVERTO_SLUG)&.read_attribute(:default_brand_palette)
  end
end
