# An app-wide request budget for an outbound third-party API (P1-11).
#
# Distinct from Rails' `rate_limit`, which caps ONE caller: 50 respondents each
# staying inside a 30-per-minute per-IP limit still produce 1,500 requests a
# minute at a provider that allows one per second. What has to be bounded here
# is the app's total outbound rate, across every request thread and every
# process, which is why the counter lives in Rails.cache (Solid Cache on the
# database since P0-5) rather than in a class variable.
#
# Fixed one-second windows rather than a true token bucket. The tradeoff, stated
# rather than hidden: requests can cluster at a window boundary, so a burst of
# up to 2x the cap is possible across two adjacent windows. That is a rounding
# error next to the unbounded behaviour it replaces, and it needs one cache
# operation instead of the read-modify-write a real bucket would take.
#
# Callers that exceed the budget are told so and DEGRADE — they must not sleep.
# Blocking a Puma thread to wait for a third-party quota is the exact failure
# mode P0-3 and P1-5 were about.
class SharedRateLimiter
  # Slightly longer than the window so a counter can't outlive its usefulness
  # but also can't expire mid-window under clock skew.
  TTL = 5

  def initialize(name, per_second:)
    @name       = name
    @per_second = per_second.to_i
  end

  # True when this call fits inside the budget; false when it should be skipped.
  #
  # Fails OPEN when the cache can't count (:null_store returns nil from
  # increment). That matches the behaviour this replaces — no throttle at all —
  # so a misconfigured cache degrades to the status quo rather than silently
  # disabling location search everywhere.
  def allow?
    return true if @per_second <= 0

    count = Rails.cache.increment(window_key, 1, expires_in: TTL)
    return true if count.nil?

    count <= @per_second
  end

  private

  def window_key
    "shared-rate:#{@name}:#{Time.now.to_i}"
  end
end
