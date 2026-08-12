# Freeze-at-approval, the suite's load-bearing rule: approving a send (now
# or scheduled) compiles the document and snapshots everything that decides
# what goes out — compiled_html/compiled_text plus {subject, preheader,
# subject_variants, audience, from_name, reply_to} in scheduled_snapshot.
# The live row stays editable afterwards; the dispatcher reads ONLY the
# frozen copy, so late edits land on the next send, never this one.
#
# Root-relative asset paths (uploaded image blocks) are absolutized here —
# email clients have no origin to resolve against — and the link pass runs
# here too, so tracked destinations are exactly what was approved.
module Comms
  module CampaignFreezer
    Result = Struct.new(:ok?, :error)

    module_function

    def call(campaign, scheduled_for: nil)
      return Result.new(false, "This campaign is no longer editable.") unless campaign.editable?
      return Result.new(false, "Give the email a subject first.") if campaign.subject.blank?

      warnings = campaign.warnings
      return Result.new(false, warnings.first) if warnings.any?

      audience = campaign.audience.presence || {}
      return Result.new(false, "The audience is empty — nobody would receive this.") if AudienceResolver.count(audience).zero?

      html = EmailRenderer.render_html(campaign.document, preheader: campaign.preheader)
      html = absolutize(html)
      campaign.email_campaign_links.delete_all
      html = LinkExtractor.extract!(campaign, html)
      text = EmailRenderer.render_text(campaign.document)

      campaign.update!(
        compiled_html: html,
        compiled_text: text,
        scheduled_snapshot: {
          "subject"          => campaign.subject,
          "preheader"        => campaign.preheader,
          "subject_variants" => Array(campaign.subject_variants).first(3).map(&:to_s).reject(&:blank?),
          "audience"         => audience,
          "from_name"        => campaign.from_name,
          "reply_to"         => campaign.reply_to
        },
        scheduled_for: scheduled_for,
        status: "scheduled"
      )
      Result.new(true, nil)
    end

    # Called from "cancel schedule": back to a plain draft, frozen copy gone.
    def unfreeze!(campaign)
      return unless campaign.scheduled?

      campaign.email_campaign_links.delete_all
      campaign.update!(compiled_html: nil, compiled_text: nil,
                       scheduled_snapshot: nil, scheduled_for: nil, status: "draft")
    end

    def absolutize(html)
      origin = Comms.app_origin
      return html if origin.blank?

      html.gsub(/(src|href)="\/(?!\/)/) { %(#{Regexp.last_match(1)}="#{origin}/) }
    end
  end
end
