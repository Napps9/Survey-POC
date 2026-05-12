class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy
end
