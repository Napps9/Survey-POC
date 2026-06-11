class SurveyRegionLink < ApplicationRecord
  belongs_to :survey
  has_many :responses, dependent: :nullify

  before_validation :generate_token, on: :create
  before_validation { self.country_code = country_code.to_s.upcase.presence }

  validates :token, presence: true, uniqueness: true
  validates :country_code, presence: true,
            inclusion: { in: ->(_) { WorldRegions::COUNTRIES.keys }, message: "is not a country code" }
  validates :label, length: { maximum: 60 }, uniqueness: { scope: [ :survey_id, :country_code ] }

  def country_name
    WorldRegions.name_for(country_code)
  end

  # "United Kingdom · Yorkshire" or just "United Kingdom" for country-level tags.
  def display_name
    label.present? ? "#{country_name} · #{label}" : country_name
  end

  # Stable identity of the region itself (not the link), used to group
  # responses: two links to the same country+label would aggregate together.
  def region_key
    "#{country_code}|#{label}"
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(18)
  end
end
