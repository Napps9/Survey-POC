class Response < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_share, optional: true
  belongs_to :survey_region_link, optional: true
  validates :session_token, presence: true, uniqueness: true

  # Keep the denormalised `answered` flag (answered ≥1 question with a value) in
  # sync on every save, so the dashboard can count responders with a grouped SQL
  # query instead of loading every response's answers JSON. See the
  # add_answered_to_responses migration.
  before_save :sync_answered

  # "GB|Yorkshire" — matches SurveyRegionLink#region_key for grouping.
  def region_key
    region_country.present? ? "#{region_country}|#{region_label}" : nil
  end

  # Whether this response holds a real answer to at least one question (a value
  # present on any card). Drives the `answered` column / responder counts.
  def content_answered?
    answers.is_a?(Hash) && answers.values.any? { |a| a.is_a?(Hash) && a["value"].present? }
  end

  private

  def sync_answered
    self.answered = content_answered?
  end
end
