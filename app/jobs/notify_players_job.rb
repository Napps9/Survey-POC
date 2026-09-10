# Tells the people who kept a Verto that there is news about it.
#
# Batched and self-chaining in the Comms::SendCampaignBatchJob shape, and for
# the same reason: this app runs two Solid Queue worker threads inside the web
# process, so a Verto with a thousand respondents must not hold one of them for
# the whole send. Each invocation takes a batch, mails it with a throttle, and
# re-enqueues itself for the rest.
#
# Claim-then-send is the at-most-once rule here too, but the claim is a row
# rather than a status flip: PlayerNotification.claim wins on a unique index,
# so a retried job, a double-pressed button and two workers racing all
# resolve to one mail. A claimed-but-unsent row (a crash between the two) is
# the honest failure — one person hears nothing, rather than everyone hearing
# twice.
class NotifyPlayersJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 25
  THROTTLE = 0.1

  discard_on StandardError do |job, error|
    ErrorReporting.report("NotifyPlayersJob", error, survey_id: job.arguments.first)
  end

  def perform(survey_id, kind)
    survey = Survey.find_by(id: survey_id)
    return if survey.nil? || survey.deleted_at.present?
    return unless PlayerNotification::KINDS.include?(kind)
    # A follow-up notice is about the Vertos this one points at, and the
    # creator can unpoint them between pressing the button and the job
    # running.
    return if kind == "follow_up" && survey.follow_up_surveys.empty?

    # Already-notified players are excluded in SQL rather than claimed and
    # discarded, so the chain terminates: without this the same batch would
    # come back forever once every claim started failing.
    told = PlayerNotification.where(survey_id: survey.id, kind: kind).select(:player_id)
    batch = PlayerAudience.for_survey(survey).where.not(id: told).order(:id).limit(BATCH_SIZE).to_a
    return if batch.empty?

    batch.each { |player| notify(player, survey, kind) }

    # More to do — go round again rather than looping here, so the thread is
    # yielded between batches.
    NotifyPlayersJob.perform_later(survey_id, kind)
  end

  private

  def notify(player, survey, kind)
    # Re-checked per player: the scope above was built before this loop
    # started, and someone unsubscribing mid-send must not still be mailed.
    return unless PlayerAudience.deliverable?(player, survey)

    notification = PlayerNotification.claim(player: player, survey: survey, kind: kind)
    return if notification.nil? # somebody else got there first

    PlayerNotificationMailer.with(notification: notification).public_send(kind).deliver_now
    notification.sent!
    sleep THROTTLE
  rescue => e
    # One bad address must not stop the send. The row stays unsent, which is
    # what "we tried and it didn't go" looks like in the database.
    ErrorReporting.report("NotifyPlayersJob#notify", e, survey_id: survey.id)
  end
end
