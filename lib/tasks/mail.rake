namespace :mail do
  desc "Send a plain test email to EMAIL=you@x.com so SMTP config can be verified"
  task test: :environment do
    to = ENV["EMAIL"] || abort("EMAIL=you@x.com is required")

    puts "── Action Mailer config ──"
    puts "  delivery_method = #{ActionMailer::Base.delivery_method.inspect}"
    puts "  smtp_settings   = #{ActionMailer::Base.smtp_settings.except(:password).inspect}"
    puts "  default[:from]  = #{ApplicationMailer.default[:from].inspect}"
    puts "  url host        = #{Rails.application.routes.default_url_options[:host].inspect}"
    puts

    print "Sending to #{to}... "
    mail = Mail.new
    mail.from    ApplicationMailer.default[:from]
    mail.to      to
    mail.subject "Playverto SMTP smoke test (#{Time.current.iso8601})"
    mail.body    "If you can read this, SMTP works."
    mail.delivery_method :smtp, ActionMailer::Base.smtp_settings
    mail.deliver!

    puts "OK"
  rescue => e
    puts "FAILED"
    puts "#{e.class}: #{e.message}"
    e.backtrace.first(10).each { |l| puts "  #{l}" }
    exit 1
  end

  desc "Trigger the real PasswordsMailer.reset for EMAIL=user@x.com (must exist)"
  task reset: :environment do
    to   = ENV["EMAIL"] || abort("EMAIL=user@x.com is required")
    user = User.find_by(email_address: to.strip.downcase) || abort("No user with that email")

    print "Sending reset to #{user.email_address}... "
    PasswordsMailer.reset(user).deliver_now
    puts "OK"
  rescue => e
    puts "FAILED"
    puts "#{e.class}: #{e.message}"
    e.backtrace.first(10).each { |l| puts "  #{l}" }
    exit 1
  end
end
