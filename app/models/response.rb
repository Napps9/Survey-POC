class Response < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_share, optional: true
  validates :session_token, presence: true, uniqueness: true

  # Small-cell suppression for region groupings: any region/results view
  # grouped by region_country should drop groups smaller than this before
  # display, so a single respondent (or a handful) is never singled out on a
  # map or in a per-country breakdown — the same threshold official
  # statistics bodies (e.g. the UK ONS) use for suppressing small cells.
  MIN_REGION_SAMPLE_SIZE = 5

  # Keep the denormalised `answered` flag (answered ≥1 question with a value) in
  # sync on every save, so the dashboard can count responders with a grouped SQL
  # query instead of loading every response's answers JSON. See the
  # add_answered_to_responses migration.
  before_save :sync_answered

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
