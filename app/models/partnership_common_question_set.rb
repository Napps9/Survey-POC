class PartnershipCommonQuestionSet < ApplicationRecord
  belongs_to :partnership
  belongs_to :common_question_set

  validates :common_question_set_id, uniqueness: { scope: :partnership_id }
end
