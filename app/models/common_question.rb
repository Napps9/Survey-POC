class CommonQuestion < ApplicationRecord
  belongs_to :common_question_set, inverse_of: :common_questions

  validates :text,      presence: true
  validates :card_type, presence: true, inclusion: { in: ->(_) { SurveyGenerator::CARD_TYPES } }
  validates :position,  presence: true

  before_validation :assign_position, on: :create

  # Hash shaped like a survey card so it can be spliced into Survey#cards. The
  # snapshot fields (common_question_id, common_question_set_id) are what
  # cross-Verto results aggregation keys on.
  def to_card
    {
      "type"                    => card_type,
      "text"                    => text,
      "description"             => description.presence,
      "options"                 => Array(options).presence,
      "allow_other"             => allow_other.presence,
      "common_question_id"      => id,
      "common_question_set_id"  => common_question_set_id
    }.compact
  end

  private

  def assign_position
    self.position ||= (common_question_set&.common_questions&.maximum(:position) || -1) + 1
  end
end
