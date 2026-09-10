# News about a Verto a respondent kept: what it changed, or what is next.
#
# The ORGANISATION is the sender in the reader's eyes and Playverto is the
# "via". That is the relationship the address was given for, and it is also
# what makes a per-organisation unsubscribe legible: "only stop emails from
# Riverside Youth Trust" is a sentence about somebody the reader recognises.
#
# Localised explicitly, in the WelcomeMailer shape, because a mailer runs in a
# Solid Queue job with no request and therefore no Current.locale.
#
# Both unsubscribe links go in every message, and the narrow one goes first —
# see PlayerEmailPreference for why offering only the global one would mean
# offering "stop everything Playverto ever sends you" to somebody who wants
# fewer emails from one council.
class PlayerNotificationMailer < ApplicationMailer
  before_action :load_notification

  def impact
    deliver_as("player_notification_mailer.impact.subject_org")
  end

  def follow_up
    @follow_ups = @survey.follow_up_surveys
    deliver_as("player_notification_mailer.follow_up.subject_org")
  end

  private

  def load_notification
    @notification = params[:notification]
    @player   = @notification.player
    @survey   = @notification.survey
    @org_name = @notification.organisation.name
    # Bound to THIS send rather than to the account, so a forwarded email
    # cannot be used to opt somebody else out of anything.
    @stop_org = player_unsubscribe_url(@notification.token, scope: "organisation")
    @stop_all = player_unsubscribe_url(@notification.token, scope: "all")
    @account  = you_url
  end

  # One place for everything both messages share, so a second kind cannot
  # accidentally ship without the unsubscribe headers.
  #
  # Takes the subject's KEY, not a rendered string: a mailer action runs in
  # whatever locale the Solid Queue job happens to have (which is the default,
  # since a job has no request and no Current.locale), and only the block below
  # switches to the reader's. Rendering the subject at the call site therefore
  # put it outside that block — an English subject line over a French body,
  # invisible while these strings existed in en.yml alone and visible the day
  # they were translated. PlayerSignInMailer and WelcomeMailer both already
  # build their subject inside the block; this now matches them.
  def deliver_as(subject_key)
    I18n.with_locale(SupportedLocales.coerce(@player.preferred_locale)) do
      headers["X-Entity-Ref-ID"] = SecureRandom.uuid
      # RFC 8058. The narrow opt-out is the one a mail client's own
      # "unsubscribe" button reaches, because it is the one that matches what
      # the reader thinks they are stopping: this sender.
      headers["List-Unsubscribe"] = "<#{@stop_org}>"
      headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
      mail(to: @player.email_address,
           subject: t(subject_key, org: @org_name),
           reply_to: ENV["MAIL_REPLY_TO"].presence)
    end
  end
end
