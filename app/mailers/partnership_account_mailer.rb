class PartnershipAccountMailer < ApplicationMailer
  def welcome(user, partnership)
    @user = user
    @partnership = partnership
    @setup_url = edit_partner_account_setup_url(user.generate_token_for(:account_setup))
    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(
      to:       user.email_address,
      subject:  "You've been added to #{partnership.name} on Playverto",
      reply_to: ENV["MAIL_REPLY_TO"].presence
    )
  end
end
