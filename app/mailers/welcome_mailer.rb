# The getting-started email (P2-6a).
#
# Sent after the address is CONFIRMED, not at signup. Signup already sends the
# P0-8 confirmation mail, and a second one alongside it would double the volume
# landing on an address nobody has yet proved is deliverable — the worst
# possible first impression to give a spam filter. Waiting means this arrives at
# an address that has just been proven good, in the same minute someone clicked
# a link in their inbox, which is also the moment they are most likely to act on
# it.
#
# Localised, unlike the mailers that came before it. A mailer runs in a Solid
# Queue job with no request and therefore no Current.locale, so the recipient's
# own `preferred_locale` has to be applied explicitly — without that the subject
# and body render in whatever locale the worker happened to be left in.
class WelcomeMailer < ApplicationMailer
  def welcome(user)
    @user = user

    I18n.with_locale(SupportedLocales.coerce(user.preferred_locale)) do
      # Threading hint so a mail client files this separately from the
      # confirmation rather than stacking the two together.
      headers["X-Entity-Ref-ID"] = SecureRandom.uuid
      mail(
        to:       user.email_address,
        subject:  t("welcome_mailer.subject"),
        reply_to: ENV["MAIL_REPLY_TO"].presence
      )
    end
  end
end
