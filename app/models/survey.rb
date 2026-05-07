class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
end
