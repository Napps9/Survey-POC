# One address a campaign reaches, snapshotted at flip-to-sending. The random
# token is the row's public identity (tracking pixel, click redirect,
# unsubscribe) — ids never leave the building. Engagement writes use
# update_columns: tracking endpoints are high-volume, unauthenticated and
# must never trip validations on years-old rows.
class EmailCampaignRecipient < ApplicationRecord
  STATUSES = %w[queued sending sent delivered simulated bounced failed skipped].freeze

  has_secure_token :token, length: 24

  belongs_to :email_campaign
  belongs_to :user, optional: true
  belongs_to :email_list_contact, optional: true

  normalizes :email, with: ->(e) { Comms.normalize_email(e) }

  validates :email, presence: true
  validates :status, inclusion: { in: STATUSES }

  # An open proves delivery; only a plain "sent" is promoted (a simulated or
  # bounced row keeps its more specific truth).
  def record_open!
    now = Time.current
    update_columns(
      first_opened_at: first_opened_at || now, last_opened_at: now,
      open_count: open_count + 1,
      delivered_at: delivered_at || now,
      status: status == "sent" ? "delivered" : status
    )
  end

  # A click implies an open implies delivery.
  def record_click!
    now = Time.current
    update_columns(
      first_clicked_at: first_clicked_at || now, last_clicked_at: now,
      click_count: click_count + 1,
      first_opened_at: first_opened_at || now, last_opened_at: now,
      delivered_at: delivered_at || now,
      status: status == "sent" ? "delivered" : status
    )
  end
end
