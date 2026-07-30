# frozen_string_literal: true

# rack-timeout ships a railtie that inserts the middleware for us — at a 15
# second bound for every request, which would kill generation, import, the
# exports and every stream on contact. The Gemfile therefore requires
# "rack/timeout/base" (the middleware alone, no railtie) and we insert our own
# tiered wrapper here instead, in the same position the railtie would have used.
#
# See lib/request_timeout.rb for the tiers and why each endpoint sits where it does.
require Rails.root.join("lib/request_timeout")

if RequestTimeout.enabled?
  Rails.application.config.middleware.insert_after(
    ActionDispatch::RequestId,
    RequestTimeout::Middleware
  )
end
