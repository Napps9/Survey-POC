class SurveyShare < ApplicationRecord
  belongs_to :survey
  belongs_to :alliance, optional: true
  has_many :responses, dependent: :nullify

  before_validation :generate_share_token, on: :create
  validates :share_token, presence: true, uniqueness: true

  def partner_organisation
    alliance&.partner_organisation
  end

  def display_name
    label.presence || partner_organisation&.name || "Partner link"
  end

  private

  def generate_share_token
    self.share_token ||= SecureRandom.urlsafe_base64(18)
  end
end
