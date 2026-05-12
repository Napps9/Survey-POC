class Response < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_share, optional: true
  validates :session_token, presence: true, uniqueness: true
end
