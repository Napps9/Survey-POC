class CommonQuestionSet < ApplicationRecord
  belongs_to :organisation
  has_many :common_questions, -> { order(:position) }, dependent: :destroy, inverse_of: :common_question_set

  # The share rows that put this set in front of a partnership. Partnership
  # already declares the mirror of this; without it here, destroying a set left
  # the join rows behind — harmless while they were unconstrained, but the
  # foreign key added in P1-9 turns that orphaning into an aborted destroy.
  #
  # Not hypothetical: Organisation destroys its common_question_sets, and a set
  # can be shared with a partnership belonging to a DIFFERENT organisation,
  # whose join rows the owning org's cascade never touches.
  has_many :partnership_common_question_sets, dependent: :destroy

  validates :name, presence: true

  scope :recent,   -> { order(updated_at: :desc) }
  scope :kept,     -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

  def deleted?
    deleted_at.present?
  end

  def archive!
    update!(deleted_at: Time.current)
  end

  # Surveys in the same organisation whose `cards` JSON snapshot any question
  # from this set. Filters in Ruby because `cards` is a JSON column without a
  # GIN index — organisations have small Verto counts, so this is cheap and
  # works identically on SQLite (dev) and Postgres (prod).
  def surveys_using(scope = organisation.surveys)
    scope.to_a.select do |survey|
      Array(survey.cards).any? { |c| c.is_a?(Hash) && c["common_question_set_id"] == id }
    end
  end
end
