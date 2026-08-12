# Append-only engagement log for Comms (opens, clicks, unsubscribes,
# delivery outcomes). Rows are facts; nothing updates them.
class EmailEvent < ApplicationRecord
  KINDS = %w[queued sent delivered open click bounce complaint unsubscribe failed simulated skipped].freeze

  belongs_to :email_campaign, optional: true
  belongs_to :email_campaign_recipient, optional: true
  belongs_to :email_automation_run, optional: true

  validates :kind, inclusion: { in: KINDS }

  def self.log!(kind, recipient: nil, campaign: nil, automation_run: nil, url: nil, meta: nil)
    create!(
      kind: kind,
      email_campaign_recipient: recipient,
      email_campaign: campaign || recipient&.email_campaign,
      email_automation_run: automation_run,
      url: url, meta: meta, occurred_at: Time.current
    )
  end
end
