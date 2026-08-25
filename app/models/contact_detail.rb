# One respondent's volunteered contact details for one Verto — the identified
# half of the split the contact feature is built on. Their ANSWERS live on
# Response rows and stay pseudonymous; their NAME lives here; and the only
# thing joining the two is key_digest, the same per-survey HMAC of the durable
# player key that assigns their leaderboard alias (PlayerAlias). The HMAC is
# per-survey on purpose: contacts, like aliases, cannot be joined across
# Vertos.
#
# Survey#contact_form_excludes_neurodiversity is the other half of the GDPR
# posture: a Verto may hold this table's rows or ask the neurodiversity
# question, never both — health-adjacent special-category answers never sit
# next to a name and an email. Age, location, gender and heritage may coexist
# with a contact form (owner's call, 2026-08-24).
class ContactDetail < ApplicationRecord
  belongs_to :survey

  # The four fields the retired contact_form card collected — kept as the
  # vocabulary (results/exports already know how to present them) with the
  # storage moved out of the answers.
  FIELDS = Survey::CONTACT_FIELDS

  MAX_FIELD = 120

  validates :key_digest, presence: true, uniqueness: { scope: :survey_id }
  validate  :some_detail_present

  # Idempotent (survey, identity) → details write, PlayerAlias.ensure_for!'s
  # shape: re-registering updates the row rather than duplicating the person,
  # and the unique index turns a concurrent first write into a retry.
  def self.upsert_for!(survey:, key_digest:, fields:)
    clean = sanitize_fields(fields)
    return nil if clean.empty?

    record = find_or_initialize_by(survey_id: survey.id, key_digest: key_digest)
    record.assign_attributes(clean)
    record.save!
    record
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  # Only the four known fields, stripped and bounded; blanks dropped so a
  # partial update never blanks a field the respondent filled last time.
  def self.sanitize_fields(fields)
    return {} unless fields.respond_to?(:[])

    FIELDS.each_with_object({}) do |f, out|
      v = fields[f].to_s.strip
      out[f] = v.first(MAX_FIELD) if v.present?
    end
  end

  private

  # A row with an identity but no details says nothing — refuse it rather than
  # count phantom contacts.
  def some_detail_present
    errors.add(:base, "needs at least one detail") if FIELDS.all? { |f| self[f].blank? }
  end
end
