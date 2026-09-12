# One language's translation run. See the migration for why this exists.
class SurveyTranslation < ApplicationRecord
  belongs_to :survey

  STATUSES = %w[queued running done failed].freeze
  # Two retries after the first attempt. A Claude call that fails three times
  # is not going to succeed on a fourth, and a creator staring at "Translating…"
  # is owed an answer sooner than an exponential backoff would give one.
  MAX_ATTEMPTS = 3

  validates :locale, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where(status: %w[queued running]) }

  def self.index_for(survey)
    where(survey_id: survey.id).index_by(&:locale)
  end

  # Mark a language as asked for. Resets a previous failure so a retry from the
  # rail is a fresh run rather than one that starts already out of attempts.
  def self.enqueue!(survey, locale)
    row = find_or_initialize_by(survey_id: survey.id, locale: locale.to_s)
    row.update!(status: "queued", attempts: 0, last_error: nil,
                started_at: nil, finished_at: nil)
    row
  end

  def running!(at: Time.current)
    update!(status: "running", attempts: attempts + 1, started_at: at, last_error: nil)
  end

  def done!
    update!(status: "done", finished_at: Time.current, last_error: nil)
  end

  # A failure that still has attempts left stays `queued`, because that is what
  # it is — the job is coming back. Only a spent one is `failed`, which is the
  # state the rail offers a retry on.
  def failed!(error, retryable:)
    update!(status: retryable && attempts < MAX_ATTEMPTS ? "queued" : "failed",
            last_error: error.to_s.first(300), finished_at: Time.current)
  end

  def in_progress? = %w[queued running].include?(status)
end
