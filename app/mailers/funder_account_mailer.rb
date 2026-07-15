class FunderAccountMailer < ApplicationMailer
  def welcome(user, funder)
    @user = user
    @funder = funder
    @setup_url = edit_funder_account_setup_url(user.generate_token_for(:account_setup))
    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(
      to:       user.email_address,
      subject:  "You've been licensed under #{funder.name} on Playverto",
      reply_to: ENV["MAIL_REPLY_TO"].presence
    )
  end
end
