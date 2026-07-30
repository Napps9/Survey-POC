require "test_helper"

# P1-11. Rails' `rate_limit` caps one caller; nothing capped the app's TOTAL
# outbound rate to the geocoder. Fifty respondents each staying politely inside
# the 30-per-minute per-IP limit still produce 1,500 requests a minute at a
# provider whose policy allows one per second — and the consequence of breaching
# it is an IP ban that takes location search down for everyone.
#
# Correction to the plan's note on this item: it cited a non-thread-safe class
# variable in `nominatim_geocode_client.rb:86`. That file does not exist — there
# is one client, and it had no throttle of any kind. The per-IP limit on
# PlayerController#location_search does exist, contrary to "respondent search
# has no throttle".
class SharedRateLimiterTest < ActiveSupport::TestCase
  # The budget is keyed to Time.now.to_i, so calls that straddle a second
  # boundary get a fresh window — which would make every "must be refused"
  # assertion below flaky. Freeze the clock: what's under test is the counting,
  # not the wall clock.
  def with_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:solid_cache_store)
    SolidCache::Entry.delete_all
    travel_to(Time.utc(2026, 7, 30, 12, 0, 0)) { yield }
  ensure
    SolidCache::Entry.delete_all
    Rails.cache = previous
  end

  test "calls inside the budget are allowed" do
    with_cache do
      limiter = SharedRateLimiter.new("t-#{SecureRandom.hex(3)}", per_second: 3)
      assert limiter.allow?
      assert limiter.allow?
      assert limiter.allow?
    end
  end

  test "the call past the budget is refused" do
    with_cache do
      limiter = SharedRateLimiter.new("t-#{SecureRandom.hex(3)}", per_second: 2)
      assert limiter.allow?
      assert limiter.allow?
      assert_not limiter.allow?, "the third call in the same second must be refused"
    end
  end

  test "the budget is shared between separate limiter instances" do
    # The whole point: two Puma threads, or two processes, must draw on one
    # budget. A per-instance counter would give each its own.
    name = "t-#{SecureRandom.hex(3)}"
    with_cache do
      2.times { SharedRateLimiter.new(name, per_second: 2).allow? }
      assert_not SharedRateLimiter.new(name, per_second: 2).allow?,
                 "a second thread must see the first one's spend"
    end
  end

  test "separate budgets do not interfere" do
    with_cache do
      a = SharedRateLimiter.new("a-#{SecureRandom.hex(3)}", per_second: 1)
      b = SharedRateLimiter.new("b-#{SecureRandom.hex(3)}", per_second: 1)
      assert a.allow?
      assert b.allow?, "b's budget is its own"
      assert_not a.allow?
    end
  end

  test "a zero or negative budget disables the limiter" do
    with_cache do
      limiter = SharedRateLimiter.new("t-#{SecureRandom.hex(3)}", per_second: 0)
      5.times { assert limiter.allow? }
    end
  end

  test "a cache that cannot count fails open" do
    # :null_store, the suite default. Failing closed would disable location
    # search everywhere the moment the cache was misconfigured; failing open
    # degrades to the unthrottled behaviour this replaces.
    limiter = SharedRateLimiter.new("t-#{SecureRandom.hex(3)}", per_second: 1)
    5.times { assert limiter.allow? }
  end
end
