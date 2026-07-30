require "test_helper"

# Rails.cache had no production configuration, so it fell back to a per-process
# in-memory store (P0-5). Nothing failed loudly — it just meant every
# `rate_limit` in the app counted per Puma process and reset on each deploy and
# each memory-watchdog restart, and the geocode/translation caches were thrown
# away as often.
#
# These tests exercise the real SolidCache::Store against the real table rather
# than asserting on config values, because the two ways this breaks in
# production are both invisible to a config assertion: pointing the store at a
# database that doesn't exist, and configuring the store without running the
# migration that gives it somewhere to write.
class CacheStoreTest < ActionDispatch::IntegrationTest
  def solid_cache_store
    ActiveSupport::Cache.lookup_store(:solid_cache_store)
  end

  test "the cache lives in the primary database, not a separate one" do
    # The generator's template ships `database: cache`, which would send Solid
    # Cache looking for a second database entry this app doesn't have. Solid
    # Queue and Solid Cable are both in the primary database for the same
    # reason, and this is the assertion that keeps the third one honest.
    assert_nil SolidCache.configuration.connects_to,
               "Solid Cache should use the primary connection, not a separate database"
    assert_not SolidCache.configuration.sharded?
  end

  test "the entries table exists, so a configured store has somewhere to write" do
    assert ActiveRecord::Base.connection.table_exists?("solid_cache_entries"),
           "config.cache_store = :solid_cache_store without the migration is a production 500 on first write"
  end

  test "the production store round-trips a value" do
    store = solid_cache_store
    key   = "cache-store-test/#{SecureRandom.hex(6)}"

    store.write(key, { "a" => 1 })
    assert_equal({ "a" => 1 }, store.read(key))

    store.delete(key)
    assert_nil store.read(key)
  end

  test "the production store supports increment, which is what rate_limit needs" do
    # Rails' `rate_limit` is built on cache.increment. A store that doesn't
    # implement it doesn't throttle — it raises, or silently never counts.
    store = solid_cache_store
    key   = "cache-store-test/counter/#{SecureRandom.hex(6)}"

    assert_equal 1, store.increment(key, 1, expires_in: 1.minute)
    assert_equal 2, store.increment(key, 1, expires_in: 1.minute)
    assert_equal 3, store.increment(key, 1, expires_in: 1.minute)
  end

  test "a rate-limit counter is shared between independent store instances" do
    # This is the whole point of P0-5. `rate_limit` counts with
    # cache.increment, and on the old per-process memory store two Puma
    # processes — or the same process either side of a memory-watchdog restart
    # — each kept their own count, so a "10 per 3 minutes" limit was really 10
    # per process per deploy. Two separately-built stores stand in for that
    # here: on a memory store the second would start again from 1.
    key = "rate-limit:sessions:#{SecureRandom.hex(6)}"

    10.times { solid_cache_store.increment(key, 1, expires_in: 3.minutes) }

    fresh_process = solid_cache_store
    assert_equal 11, fresh_process.increment(key, 1, expires_in: 3.minutes),
                 "a second process must continue the first one's count, not restart it"
  ensure
    SolidCache::Entry.delete_all
  end

  test "the rate limiters read the application cache store rather than one of their own" do
    # `rate_limit` resolves `store:` from ActionController::Base.cache_store at
    # class-definition time, which Rails derives from config.cache_store during
    # initialization. That derivation is what carries
    # `config.cache_store = :solid_cache_store` through to every throttle in
    # the app, and it is silently broken by setting
    # config.action_controller.cache_store to something else.
    #
    # Honest scope: this asserts the invariant in the TEST environment (both
    # are :null_store here — which is also why no `rate_limit` in this app can
    # be exercised end-to-end by the suite). It catches a divergence introduced
    # in application.rb or a shared initializer, not one introduced only in
    # production.rb.
    assert_same Rails.cache, ActionController::Base.cache_store,
                "the controller cache store must follow config.cache_store"
  end
end
