# A "do not email" fact. The audience resolver subtracts these rows from
# every campaign and automation send — an address lands here from the
# unsubscribe endpoint, a hard bounce, a complaint, or a manual entry, and
# from then on simply stops existing as far as Comms is concerned.
class EmailSuppression < ApplicationRecord
  REASONS = %w[unsubscribe hard_bounce complaint manual].freeze

  normalizes :email, with: ->(e) { Comms.normalize_email(e) }

  validates :email, presence: true, uniqueness: true
  validates :reason, inclusion: { in: REASONS }

  # Idempotent upsert: the first reason wins (a complaint recorded after an
  # unsubscribe changes nothing about deliverability). Race-safe via the
  # unique index: a concurrent insert surfaces as RecordInvalid/NotUnique
  # and resolves to the existing row.
  def self.record!(email, reason:, user_id: nil, source_campaign_id: nil)
    normalized = Comms.normalize_email(email)
    return if normalized.blank?

    find_or_create_by!(email: normalized) do |s|
      s.reason = reason
      s.user_id = user_id
      s.source_campaign_id = source_campaign_id
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by(email: normalized)
  end
end
