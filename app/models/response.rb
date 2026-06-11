class Response < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_share, optional: true
  belongs_to :survey_region_link, optional: true
  validates :session_token, presence: true, uniqueness: true

  # "GB|Yorkshire" — matches SurveyRegionLink#region_key for grouping.
  def region_key
    region_country.present? ? "#{region_country}|#{region_label}" : nil
  end
end
