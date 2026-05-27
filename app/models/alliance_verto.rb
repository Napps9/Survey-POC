class AllianceVerto < ApplicationRecord
  belongs_to :alliance
  belongs_to :survey
  has_many :survey_shares, dependent: :destroy
end
