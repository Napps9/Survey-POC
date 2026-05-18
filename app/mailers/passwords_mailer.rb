class PasswordsMailer < ApplicationMailer
  def reset(user)
    @user = user
    headers["X-Entity-Ref-ID"] = SecureRandom.uuid
    mail(
      to:       user.email_address,
      subject:  "Reset your Playverto password",
      reply_to: ENV["MAIL_REPLY_TO"].presence
    )
  end
end
