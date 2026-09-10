# Tells someone when respondent traffic climbs. Nothing else does: Sentry
# reports errors, an uptime monitor reports outages, and both answer "is it
# broken" rather than "is something happening". A Verto shared on social has
# no schedule — the wave arrives at 9pm three days after the event, when
# nobody is watching a dashboard, and the persistent disk pins the service to
# one instance, so nothing scales itself in response either. The point of this
# job is that a human finds out in time to scale up by hand.
#
# Inert until TRAFFIC_ALERT_EMAILS is set, like every other opt-in here.
class TrafficAlertJob < ApplicationJob
  queue_as :default

  # The window counted per run. Kept equal to the recurring schedule
  # (config/recurring.yml) so consecutive runs neither overlap nor leave gaps.
  WINDOW = 15.minutes

  # Responses per minute, app-wide, that counts as "something is happening".
  # Ten a minute is far above an ordinary day and about 12% of one measured
  # arrival second at the event rate, so it fires long before anything is at
  # risk — the alert exists to buy reaction time, not to report an emergency.
  DEFAULT_PER_MINUTE = 10

  discard_on StandardError do |job, error|
    ErrorReporting.report("TrafficAlertJob", error)
  end

  # Where spike notifications land. Comma/space-separated; empty disables the
  # job outright.
  def self.recipients
    ENV.fetch("TRAFFIC_ALERT_EMAILS", "").split(/[,\s]+/).map(&:strip).reject(&:blank?)
  end

  def self.threshold_per_minute
    Integer(ENV.fetch("TRAFFIC_ALERT_PER_MINUTE", DEFAULT_PER_MINUTE))
  rescue ArgumentError, TypeError
    DEFAULT_PER_MINUTE
  end

  # Deliberately stateless, and deliberately without a cooldown: a sustained
  # spike sends one email per window, which is at most four an hour.
  # The tidier alternative — remembering the last send in Rails.cache — would
  # go quiet exactly when the cache is under pressure, and a cache under
  # pressure is a symptom of the very traffic this is meant to report (runs
  # 19-24: the store saturated, the cache failed open, and nothing said so).
  # Four emails an hour is the cheaper failure.
  def perform(window: WINDOW)
    recipients = self.class.recipients
    return if recipients.empty?

    # One grouped pass: the totals and the per-Verto breakdown come from the
    # same scan. `responses` has no index on created_at alone — the composite
    # ones all lead with survey_id — so this is a sequential scan by design.
    # At the table's current size that is milliseconds once every fifteen
    # minutes; if it ever stops being cheap, the fix is an index on
    # created_at, not a cleverer query.
    by_survey  = Response.where(created_at: window.ago..).group(:survey_id).count
    count      = by_survey.values.sum
    per_minute = count / (window / 60.0)
    return if per_minute < self.class.threshold_per_minute

    TrafficAlertMailer.spike(
      recipients:     recipients,
      count:          count,
      per_minute:     per_minute,
      window_minutes: (window / 60).to_i,
      rows:           busiest(by_survey)
    ).deliver_now # already inside a background job; no point enqueuing another
  end

  private

  # The handful of Vertos actually driving it, so the email says what is
  # happening rather than only that something is.
  def busiest(by_survey, limit: 3)
    top = by_survey.sort_by { |_id, n| -n }.first(limit)
    surveys = Survey.where(id: top.map(&:first)).includes(:organisation).index_by(&:id)

    top.filter_map do |survey_id, n|
      survey = surveys[survey_id]
      next unless survey

      {
        name:         survey.title.presence || survey.theme,
        organisation: survey.organisation&.name,
        responses:    n
      }
    end
  end
end
