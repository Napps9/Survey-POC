# Per-user rate limits and a per-organisation daily cap on the endpoints that
# spend money at Anthropic (or Pexels).
#
# The public player and the auth endpoints were already rate-limited; the
# creator-facing AI endpoints were not, so a signed-in user — or a stuck retry
# loop in the editor, or a double-click — could queue unbounded paid
# generations (P0-4). These limits are deliberately generous: they are a
# runaway guard, not a product quota.
#
# Two mechanisms, because they stop different things:
#
#   throttle_ai   bounds the RATE per user, using Rails' own `rate_limit`.
#   cap_ai_spend  bounds the TOTAL per organisation per day, which is the thing
#                 that actually shows up on an invoice.
#
# Both only became meaningful once Rails.cache moved to Solid Cache (P0-5):
# on the old per-process memory store the counters reset on every deploy and
# every memory-watchdog restart.
module ThrottlesAiSpend
  extend ActiveSupport::Concern

  # Claude calls per organisation per UTC day across every AI endpoint. Sized
  # for a busy team building several Vertos a day with room to spare; 0
  # disables the cap entirely.
  DEFAULT_DAILY_CAP = 300

  # Kept keyed to the UTC date, so a day's counter expires on its own rather
  # than needing a sweep. Slightly over 24h so the key outlives its own day.
  CAP_TTL = 25.hours

  included do
    # Every action declared through `throttle_ai`, so a test can assert that a
    # newly added AI endpoint didn't get missed. Rails' `rate_limit` hides its
    # configuration inside a before_action lambda, which can't be introspected.
    class_attribute :ai_throttled_actions, default: [], instance_writer: false
    # The same, for `cap_ai_spend`. Its before_action is an anonymous block, so
    # without this there is no way to assert an endpoint took the daily cap —
    # and the cap is the guard that bounds what actually reaches an invoice.
    class_attribute :ai_capped_actions, default: [], instance_writer: false
  end

  class_methods do
    # `respond:` is explicit per declaration rather than sniffed from
    # request.format: these endpoints are a mix of JSON fetches and ordinary
    # form posts, and the JSON ones don't all send an Accept header, so
    # request.format would say "html" for several of them and the client would
    # get a redirect where it expected a body it could parse.
    def throttle_ai(to:, within:, name:, respond:, only:)
      actions = Array(only)
      self.ai_throttled_actions = (ai_throttled_actions + actions).uniq

      message = "You're making AI requests faster than we can pay for them — " \
                "give it a minute and try again."

      rate_limit to: to, within: within, name: name, only: actions,
                 by:   -> { ai_actor_key },
                 with: -> { deny_ai_request(respond, message) }
    end

    def cap_ai_spend(only:, respond:)
      actions = Array(only)
      self.ai_capped_actions = (ai_capped_actions + actions).uniq

      before_action(only: actions) { enforce_daily_ai_cap!(respond) }
    end
  end

  private

  # Per user, not per IP: these are all authenticated endpoints, and a whole
  # office behind one NAT'd address is a normal shape for this product. Falls
  # back to the IP so the limit can never silently become unlimited if this is
  # ever mounted somewhere unauthenticated.
  def ai_actor_key
    Current.user&.id ? "user:#{Current.user.id}" : "ip:#{request.remote_ip}"
  end

  def daily_ai_cap
    Integer(ENV.fetch("AI_DAILY_GENERATION_CAP", DEFAULT_DAILY_CAP))
  rescue ArgumentError
    DEFAULT_DAILY_CAP
  end

  def enforce_daily_ai_cap!(respond)
    org = Current.organisation
    cap = daily_ai_cap
    return if org.nil? || cap <= 0

    count = Rails.cache.increment(ai_cap_key(org), 1, expires_in: CAP_TTL)
    # A store with no increment (the suite's :null_store) returns nil. Fail
    # OPEN there: the cap is a spend guard, and breaking every AI endpoint
    # because the cache is misconfigured would be the worse failure.
    return if count.nil? || count <= cap

    deny_ai_request(respond, "This account has reached its daily AI limit. " \
                             "It resets at midnight UTC.")
  end

  def ai_cap_key(org)
    "ai-daily-cap:#{org.id}:#{Time.now.utc.to_date}"
  end

  def deny_ai_request(respond, message)
    case respond
    when :json
      render json: { ok: false, error: message }, status: :too_many_requests
    when :plain
      # The streaming endpoints write text/plain, and their clients already
      # display whatever body comes back — that's how LimitsConcurrentStreams
      # reports a full pool. Matching it means no client change.
      render plain: message, status: :too_many_requests
    else
      redirect_back fallback_location: root_path, allow_other_host: false, alert: message
    end
  end
end
