# Whether real delivery is possible. :smtp = production with SMTP_ADDRESS
# configured (config/initializers/mailer.rb); :test = the test suite, which
# must exercise the live path through the test adapter. Anything else (dev
# without SMTP) runs the whole pipeline in SIMULATED mode: recipients are
# marked simulated, events log, the campaign completes — demonstrable end to
# end with no credentials, Temple's trick.
module Comms
  module Delivery
    module_function

    def live?
      [ :smtp, :test ].include?(ActionMailer::Base.delivery_method)
    end
  end
end
