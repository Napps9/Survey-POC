# The "confirm this is your address" email sent at signup (P0-8).
class EmailConfirmationsMailer < ApplicationMailer
  def confirm(user)
    @user = user
    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(
      to:       user.email_address,
      subject:  "Confirm your Playverto email address",
      reply_to: ENV["MAIL_REPLY_TO"].presence
    )
  end
end
