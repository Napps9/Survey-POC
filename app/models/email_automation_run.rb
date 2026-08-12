# One automation firing for one subject: the ledger row IS the queue entry.
# idempotency_key (automation + subject + anchor) is UNIQUE — the enqueue
# sweep can run any number of times and a subject is only ever booked once
# per anchor. The random token is the run's public identity (pixel,
# unsubscribe), same rule as campaign recipients.
class EmailAutomationRun < ApplicationRecord
  STATUSES = %w[queued sending sent failed skipped suppressed simulated].freeze

  has_secure_token :token, length: 24

  belongs_to :email_automation
  belongs_to :email_automation_step, optional: true
  belongs_to :user, optional: true

  normalizes :email, with: ->(e) { Comms.normalize_email(e) }

  validates :email, presence: true
  validates :idempotency_key, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
end
