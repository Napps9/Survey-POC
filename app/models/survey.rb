class Survey < ApplicationRecord
  has_many :responses, dependent: :destroy
end
