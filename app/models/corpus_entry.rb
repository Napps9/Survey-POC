# One Verto's membership of the Ask Verto corpus, and the two consent gates that
# decide it.
#
# THE RULE, and there is only one:
#
#   A Verto's data may be used to answer a question when its creator has opted in,
#   has not withdrawn, AND VertoNow has approved it. All three, every time.
#
# `citable` (the scope) and `citable?` (the predicate) are the single expression of
# that rule. Every read of corpus data starts from the scope — CorpusTools has no
# other entry point — so there is exactly one place to get this right and exactly
# one place to test it.
#
# Two properties that are easy to lose and expensive to lose:
#
#   * Withdrawal is a READ-TIME filter, not a rebuild. Clearing withdrawn_at is what
#     restores a Verto; deleting its index is not required and must not be relied on.
#     A withdrawal that only took effect at the next re-index would leave a window
#     where a creator has said no and the product is still answering from their data.
#   * A decline does NOT clear the creator's opt-in. The creator said yes; if the
#     reason (too few responses, say) is later fixed, they should not have to say it
#     again. review_status moves back to pending, the opt-in stays where it was.
class CorpusEntry < ApplicationRecord
  belongs_to :survey
  belongs_to :organisation
  belongs_to :opted_in_by, class_name: "User", optional: true

  has_many :corpus_questions, dependent: :destroy

  REVIEW_STATUSES = %w[pending approved declined].freeze
  validates :review_status, inclusion: { in: REVIEW_STATUSES }

  # Small-cell suppression. Below this, a distribution starts describing
  # identifiable individuals rather than a population — the same reasoning behind
  # Response::MIN_REGION_SAMPLE_SIZE, set higher here because this data crosses an
  # organisation boundary rather than staying inside the account that collected it.
  MIN_SAMPLE_SIZE = 30

  # The creator's half of the gate: offered and not taken back.
  scope :offered, -> { where.not(opted_in_at: nil).where(withdrawn_at: nil) }

  # THE scope. Nothing reads corpus data except through this.
  scope :citable, -> { offered.where(review_status: "approved") }

  # What the review queue works through, freshest offer last so the oldest wait is
  # at the top.
  scope :awaiting_review, -> { offered.where(review_status: "pending").order(opted_in_at: :asc) }

  scope :withdrawn, -> { where.not(withdrawn_at: nil) }

  def opted_in?  = opted_in_at.present? && withdrawn_at.nil?
  def withdrawn? = withdrawn_at.present?
  def approved?  = review_status == "approved"
  def declined?  = review_status == "declined"
  def pending?   = review_status == "pending"

  # Must agree with the `citable` scope, exactly. The model test asserts that for
  # every combination rather than trusting the two to stay in step.
  def citable?
    opted_in? && approved?
  end

  # What the creator's editor panel shows. One value, so the view has no logic to
  # get subtly different from this.
  #
  #   :off        never offered, or withdrawn — the resting state
  #   :pending    offered, waiting on us
  #   :live       citable
  #   :declined   offered, we said no (review_note carries why)
  def creator_state
    return :off if opted_in_at.blank? || withdrawn?
    return :declined if declined?
    return :live if approved?

    :pending
  end

  # ── Transitions ────────────────────────────────────────────────────────────
  # Each one is a whole statement about consent, so each is its own method rather
  # than callers assembling update! calls that drift apart.

  # The creator offers the Verto. Re-offering after a withdrawal clears the
  # withdrawal and starts review again: our previous approval was granted against
  # a consent that has since been revoked, so it does not carry over.
  def opt_in!(user)
    update!(
      opted_in_at:   opted_in_at.presence || Time.current,
      opted_in_by:   opted_in_by || user,
      withdrawn_at:  nil,
      review_status: withdrawn? ? "pending" : review_status
    )
  end

  # The creator takes it back. The row stays — a withdrawal is a fact worth
  # keeping, and re-offering later should not look like a first offer.
  def withdraw!
    update!(withdrawn_at: Time.current)
  end

  def approve!(reviewer_email)
    update!(review_status: "approved", reviewed_at: Time.current,
            reviewed_by_email: reviewer_email, review_note: nil)
  end

  # A reason is required. The creator reads it verbatim, and "not accepted" tells
  # them nothing they can act on.
  def decline!(reviewer_email, note)
    update!(review_status: "declined", reviewed_at: Time.current,
            reviewed_by_email: reviewer_email, review_note: note.to_s.strip.presence || "No reason given.")
  end

  # Find-or-build for a survey, without persisting: the opt-in action creates the
  # row, and merely rendering the editor panel must not.
  def self.for(survey)
    find_by(survey_id: survey.id) ||
      new(survey: survey, organisation_id: survey.organisation_id)
  end
end
