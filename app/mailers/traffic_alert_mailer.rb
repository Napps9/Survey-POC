# The one email TrafficAlertJob sends. Staff-facing and English-only, like
# AskSubmissionMailer's team notification — it goes to whoever is on the hook
# for scaling the box, not to a respondent.
class TrafficAlertMailer < ApplicationMailer
  def spike(recipients:, count:, per_minute:, window_minutes:, rows:)
    @count          = count
    @per_minute     = per_minute
    @window_minutes = window_minutes
    @rows           = rows

    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(
      to: recipients,
      subject: "Playverto traffic: #{count} #{"response".pluralize(count)} " \
               "in #{window_minutes} minutes (#{per_minute.round} a minute)"
    )
  end
end
