class AllianceCommonQuestionSet < ApplicationRecord
  belongs_to :alliance
  belongs_to :common_question_set

  validates :common_question_set_id, uniqueness: { scope: :alliance_id }
end
