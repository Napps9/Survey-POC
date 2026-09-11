# The review state of one card's wording in one language. See the migration
# for why it is keyed by cid and why content_digest exists.
class LanguageCheck < ApplicationRecord
  belongs_to :survey
  belongs_to :reviewed_by_user, class_name: "User", optional: true
  belongs_to :language_check_link, optional: true

  STATUSES = %w[pending approved changes_requested].freeze
  MAX_NAME = 60

  validates :cid, :locale, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :approved, -> { where(status: "approved") }

  # Find-or-build for one line. Not find_or_create_by: the screen renders a
  # line for every (card, language) pair in the deck, and materialising a row
  # per line on a page VIEW would write hundreds of rows for a Verto nobody has
  # reviewed yet. Rows appear when somebody acts.
  def self.for_line(survey, cid, locale)
    find_or_initialize_by(survey_id: survey.id, cid: cid.to_s, locale: locale.to_s)
  end

  # Every stored row for a Verto, indexed the way the views want it.
  def self.index_for(survey)
    where(survey_id: survey.id).index_by { |r| [ r.cid, r.locale ] }
  end

  # Has the wording moved since this row was decided? An approval is an
  # approval of particular words (LanguageCheckLines.digest), so text edited
  # afterwards leaves the tick behind — the row stays `approved` and the screen
  # shows it as stale rather than silently downgrading a reviewer's decision to
  # pending, which would erase the fact that somebody did look at it.
  #
  # Two ways a line goes stale, and both have to count. Its OWN words changing
  # is the obvious one. The other is the primary language underneath it
  # changing: approving a Spanish line is a judgement that it says what the
  # English says, so a rewritten English question invalidates it just as surely
  # as a rewritten Spanish one. source_digest is null on primary-language rows
  # (nothing above them) and on rows decided before this was recorded, where
  # the honest answer is "we cannot tell" and the tick is left alone.
  def stale_for?(digest, source_digest_now = nil)
    return false if status == "pending"
    return true if content_digest.present? && digest.present? && content_digest != digest
    source_digest.present? && source_digest_now.present? && source_digest != source_digest_now
  end

  # The state a line is actually IN, given the words on screen right now.
  # One method so the owner's screen, the reviewer's screen and the progress
  # counter can never disagree about what a line's badge says.
  def self.state_for(row, digest, source_digest_now = nil)
    return "pending" if row.nil? || row.status == "pending"
    return "stale" if row.stale_for?(digest, source_digest_now)
    row.status
  end

  def reviewer_label
    reviewed_by_user&.name.presence || reviewed_by_name.presence
  end
end
