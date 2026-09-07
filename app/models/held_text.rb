# One free-text answer, held out of the response it belongs to until it has
# been passed — see Moderation for why the hold comes first.
#
# Lifecycle:
#
#   pending      written, waiting for ScreenHeldTextsJob
#   screening    claimed by a running screen (reverted to pending if the job
#                dies — Moderation::SCREENING_STALE_AFTER)
#   review       needs a person: the screen was unsure, the Verto is in
#                review_all mode, the screen is off, or it failed repeatedly
#   safeguarding the screen read a disclosure of harm or risk to the writer.
#                Never auto-decided, never auto-purged: a person reads it.
#   released     shown — the text is back in the answer where it was typed
#   removed      not shown — a "removed" marker sits in the answer; the text
#                stays readable to staff for Moderation::REMOVED_RETENTION and
#                is then blanked by the sweep
#   superseded   the respondent changed their answer before this one was
#                decided; the newer text has its own row
#
# The answer itself carries a marker while the row is open —
# `"held" => { "value" => true }` (or `"other" => true`, or `"removed"`) — so
# everything that reads answers can tell "answered, not shown" from "skipped".
# Response.answered_entry? counts a marker as an answer; the results
# aggregator counts it in the total; nothing renders its text, because there
# is no text there to render.
class HeldText < ApplicationRecord
  belongs_to :response
  belongs_to :survey
  belongs_to :organisation

  encrypts :text

  STATUSES = %w[pending screening review released removed safeguarding superseded].freeze
  OPEN     = %w[pending screening review safeguarding].freeze
  SLOTS    = Moderation::FreeTextSlots::SLOTS

  validates :status, inclusion: { in: STATUSES }
  validates :slot, inclusion: { in: SLOTS }
  validates :text_digest, presence: true
  validates :card_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :open,            -> { where(status: OPEN) }
  scope :awaiting_person, -> { where(status: %w[review safeguarding]) }
  scope :screenable,      -> { where(status: "pending") }

  # The lookup key the hold uses to recognise a replayed write. Whitespace at
  # the ends is not a different answer; anything else is.
  def self.digest_for(text)
    Digest::SHA256.hexdigest(text.to_s.strip)
  end

  def open?
    OPEN.include?(status)
  end

  # Put the text back into the answer and record who let it through.
  def release!(decided_by: nil, note: nil, auto: false)
    decide!("released", decided_by:, note:, auto:)
  end

  # Leave a "removed" marker in the answer's place. The text is kept, readable
  # to staff, until purge_after — long enough to answer a question about the
  # decision, and no longer.
  def remove!(decided_by: nil, note: nil, auto: false)
    decide!("removed", decided_by:, note:, auto:, purge_after: Moderation::REMOVED_RETENTION.from_now)
  end

  # Hand to a person, keeping whatever the screen concluded.
  def refer!(category: nil, certainty: nil, note: nil)
    update!(status: "review", category:, certainty:, verdict_note: note, screened_at: Time.current)
  end

  # Is this the row whose marker currently sits in the answer? A respondent
  # who edits their text gets a new row (the old one is superseded), and only
  # the newest row for a slot may write into the answer — an older one being
  # decided late must not put its stale text back.
  def current_for_slot?
    self.class.where(response_id:, card_index:, slot:)
        .where.not(status: "superseded")
        .order(:id).last&.id == id
  end

  private

  def decide!(new_status, decided_by:, note:, auto:, purge_after: nil)
    transaction do
      # Locked, because the respondent may be mid-write on this row: /progress
      # reads answers, merges and saves, and a decision landing between the
      # read and the save would be overwritten by the merged copy.
      response.with_lock do
        write_marker!(new_status) if current_for_slot?
      end
      update!(status: new_status, decided_at: Time.current, decided_by_email: decided_by,
              decision_note: note, auto:, purge_after:)
    end
  end

  def write_marker!(new_status)
    answers = response.answers.is_a?(Hash) ? response.answers.deep_dup : {}
    entry   = answers[card_index.to_s]
    return unless entry.is_a?(Hash) && entry["held"].is_a?(Hash) && entry["held"].key?(slot)

    if new_status == "released"
      entry[slot] = text
      held = entry["held"].except(slot)
      held.empty? ? entry.delete("held") : entry["held"] = held
    else
      entry[slot] = nil
      entry["held"] = entry["held"].merge(slot => "removed")
    end
    response.answers = answers
    response.save!
  end
end
