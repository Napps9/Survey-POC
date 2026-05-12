class SurveyShare < ApplicationRecord
  belongs_to :survey
  belongs_to :alliance
  has_many :responses, dependent: :nullify

  before_validation :generate_share_token, on: :create
  validates :share_token, presence: true, uniqueness: true

  delegate :partner_organisation, to: :alliance

  private

  def generate_share_token
    self.share_token ||= SecureRandom.urlsafe_base64(18)
  end
end
