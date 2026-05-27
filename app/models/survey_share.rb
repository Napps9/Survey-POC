class SurveyShare < ApplicationRecord
  belongs_to :survey
  belongs_to :alliance_verto
  belongs_to :partner_organisation, class_name: "Organisation"
  has_one :alliance, through: :alliance_verto
  has_many :responses, dependent: :nullify

  before_validation :generate_share_token, on: :create
  validates :share_token, presence: true, uniqueness: true

  def display_name
    partner_organisation&.name || "Partner link"
  end

  private

  def generate_share_token
    self.share_token ||= SecureRandom.urlsafe_base64(18)
  end
end
