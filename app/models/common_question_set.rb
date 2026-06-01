class CommonQuestionSet < ApplicationRecord
  belongs_to :organisation
  has_many :common_questions, -> { order(:position) }, dependent: :destroy, inverse_of: :common_question_set

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
