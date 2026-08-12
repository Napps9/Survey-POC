# Append-only engagement log for Comms (opens, clicks, unsubscribes,
# delivery outcomes). Rows are facts; nothing updates them.
class EmailEvent < ApplicationRecord
  KINDS = %w[queued sent delivered open click bounce complaint unsubscribe failed simulated skipped].freeze

  belongs_to :email_campaign, optional: true
  belongs_to :email_campaign_recipient, optional: true

  validates :kind, inclusion: { in: KINDS }

  def self.log!(kind, recipient: nil, campaign: nil, url: nil, meta: nil)
    create!(
      kind: kind,
      email_campaign_recipient: recipient,
      email_campaign: campaign || recipient&.email_campaign,
      url: url, meta: meta, occurred_at: Time.current
    )
  end
end
