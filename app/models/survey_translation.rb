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

  # How long a language may claim to be in progress before the screen stops
  # believing it.
  #
  # A row goes stale rather than failing when nothing CLOSED it: the process
  # was re-execed mid-call by the memory watchdog, the queue entry was lost, a
  # deploy landed on top of it. In every one of those cases the job is not
  # coming back and no code path is left to say so — so the only honest reading
  # is the clock. Generous enough that a genuinely slow deck is never called
  # dead: one Claude call per language runs in tens of seconds, and this is
  # fifteen minutes.
  STALE_AFTER = 15.minutes

  def stale?
    in_progress? && (started_at || updated_at || created_at) < STALE_AFTER.ago
  end

  # What the screen should SAY, which is not always what the column holds — a
  # row abandoned by a dead process still reads "running" for ever.
  def display_status
    return "failed" if stale?
    status
  end

  def stalled_reason
    return last_error if last_error.present?
    "this took longer than expected and stopped without finishing" if stale?
  end
end
