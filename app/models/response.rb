class Response < ApplicationRecord
  belongs_to :survey
  validates :session_token, presence: true, uniqueness: true
end
