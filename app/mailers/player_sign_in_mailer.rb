# The link a respondent asked for at the end of a Verto.
#
# Localised in the WelcomeMailer shape, and for the same reason: a mailer runs
# in a Solid Queue job with no request and therefore no Current.locale, so
# without an explicit I18n.with_locale this renders in whatever locale the
# worker was last left in.
#
# The subject names the ORGANISATION, not Playverto. The respondent has a
# relationship with the council that asked them something; we are the "via".
class PlayerSignInMailer < ApplicationMailer
  def sign_in(player, raw_token, survey)
    @player = player
    @survey = survey
    @url    = player_sign_in_url(raw_token)
    @minutes = (PlayerSignInLink::LIFETIME / 60).to_i
    @org_name = survey&.organisation&.name

    I18n.with_locale(SupportedLocales.coerce(player.preferred_locale)) do
      # Threading hint, so a second link does not stack under the first in a
      # mail client and get missed.
      headers["X-Entity-Ref-ID"] = SecureRandom.uuid
      mail(
        to:       player.email_address,
        subject:  @org_name.present? ? t("player_sign_in_mailer.subject_org", org: @org_name)
                                     : t("player_sign_in_mailer.subject"),
        reply_to: ENV["MAIL_REPLY_TO"].presence
      )
    end
  end
end
