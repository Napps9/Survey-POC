class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "Playverto <no-reply@playverto.local>")
  layout "mailer"
end
