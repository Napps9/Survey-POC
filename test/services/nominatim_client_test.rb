require "test_helper"

class NominatimClientTest < ActiveSupport::TestCase
  PLACE = {
    "display_name" => "Austin, Travis County, Texas, United States",
    "address" => {
      "city" => "Austin",
      "state" => "Texas",
      "country" => "United States",
      "country_code" => "us"
    },
    "lat" => "30.267153",
    "lon" => "-97.7430608"
  }.freeze

  test "search normalizes a Nominatim place, never exposing lat/lon" do
    stub_method(NominatimClient, :get_json, ->(_url, _params) { [ PLACE ] }) do
      results = NominatimClient.search(query: "Austin")
      assert_equal 1, results.size
      place = results.first
      assert_equal "Austin", place[:city]
      assert_equal "Texas", place[:region]
      assert_equal "United States", place[:country]
      assert_equal "US", place[:country_code]
      assert_equal "Austin, Travis County, Texas, United States", place[:display_name]
      refute place.key?(:lat)
      refute place.key?(:lon)
    end
  end

  test "search returns [] for a too-short query without hitting the network" do
    stub_method(NominatimClient, :get_json, ->(_u, _p) { raise "should not be called" }) do
      assert_equal [], NominatimClient.search(query: "ab")
      assert_equal [], NominatimClient.search(query: "  ")
    end
  end

  test "search returns [] and never raises on error" do
    stub_method(NominatimClient, :get_json, ->(_u, _p) { raise "boom" }) do
      assert_equal [], NominatimClient.search(query: "somewhere-unique-#{SecureRandom.hex(4)}")
    end
  end

  test "search drops a place with no resolvable country" do
    stub_method(NominatimClient, :get_json, ->(_u, _p) { [ { "display_name" => "Nowhere", "address" => {} } ] }) do
      assert_equal [], NominatimClient.search(query: "nowhere-unique-#{SecureRandom.hex(4)}")
    end
  end

  test "search falls back through town/village and region/state_district when city/state are absent" do
    place = {
      "display_name" => "Hallstatt, Gmunden, Upper Austria, Austria",
      "address" => { "town" => "Hallstatt", "state_district" => "Gmunden", "country" => "Austria", "country_code" => "at" }
    }
    stub_method(NominatimClient, :get_json, ->(_u, _p) { [ place ] }) do
      result = NominatimClient.search(query: "hallstatt-unique-#{SecureRandom.hex(4)}").first
      assert_equal "Hallstatt", result[:city]
      assert_equal "Gmunden", result[:region]
      assert_equal "AT", result[:country_code]
    end
  end

  test "search hits the public Nominatim server when no LocationIQ key is set" do
    seen_url = seen_params = nil
    stub_method(NominatimClient, :get_json, ->(url, params) { seen_url = url; seen_params = params; [ PLACE ] }) do
      NominatimClient.search(query: "austin-#{SecureRandom.hex(4)}")
    end
    assert_equal "https://nominatim.openstreetmap.org/search", seen_url
    assert_equal "jsonv2", seen_params[:format]
    assert_nil seen_params[:key]
  end

  test "search routes through LocationIQ with the key when LOCATIONIQ_API_KEY is set" do
    seen_url = seen_params = nil
    with_env("LOCATIONIQ_API_KEY" => "test-key", "LOCATIONIQ_REGION" => "eu1") do
      stub_method(NominatimClient, :get_json, ->(url, params) { seen_url = url; seen_params = params; [ PLACE ] }) do
        NominatimClient.search(query: "austin-#{SecureRandom.hex(4)}")
      end
    end
    assert_equal "https://eu1.locationiq.com/v1/search", seen_url
    assert_equal "json", seen_params[:format]
    assert_equal "test-key", seen_params[:key]
  end

  test "an empty result is not cached, so a transient 403 never poisons a search term" do
    # Needs headroom in the app-wide outbound budget (P1-11): this makes two
    # network calls for the same term in one second, which the default 1/s
    # would legitimately skip. The subject here is cache poisoning, not the
    # throttle — that has its own tests below.
    with_memory_cache do
      ENV["GEOCODE_MAX_RPS"] = "50"
      query = "somewhere-#{SecureRandom.hex(4)}"
      calls = 0
      stub_method(NominatimClient, :get_json, ->(_u, _p) { calls += 1; calls == 1 ? [] : [ PLACE ] }) do
        assert_equal [], NominatimClient.search(query: query)  # first lookup fails (empty)
        refute_empty NominatimClient.search(query: query)      # retries — not served a cached []
        NominatimClient.search(query: query)                   # now served from cache
      end
      assert_equal 2, calls, "empty result must not be cached; the real hit should be"
    end
  ensure
    ENV.delete("GEOCODE_MAX_RPS")
  end

  private

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  def with_env(vars)
    original = ENV.slice(*vars.keys)
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    vars.each_key { |k| original.key?(k) ? ENV[k] = original[k] : ENV.delete(k) }
  end

  # ── App-wide outbound budget (P1-11) ──────────────────────────────────────

  # Frozen clock: the budget window is one second wide, so without this a test
  # whose calls straddle a boundary silently gets a second budget and the
  # "must be skipped" assertions flake.
  def with_cache_and_rps(rps)
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:solid_cache_store)
    ENV["GEOCODE_MAX_RPS"] = rps.to_s
    SolidCache::Entry.delete_all
    travel_to(Time.utc(2026, 7, 30, 12, 0, 0)) { yield }
  ensure
    ENV.delete("GEOCODE_MAX_RPS")
    SolidCache::Entry.delete_all
    Rails.cache = previous
  end

  test "the outbound budget stops calls once the app-wide rate is spent" do
    calls = 0
    with_cache_and_rps(2) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { calls += 1; [ PLACE ] }) do
        # Distinct queries so the day-long result cache never serves them.
        assert NominatimClient.search(query: "Austin").any?
        assert NominatimClient.search(query: "Boston").any?
        assert_equal [], NominatimClient.search(query: "Chicago"),
                     "the third call in the same second must be skipped"
      end
    end
    assert_equal 2, calls, "only the calls inside the budget should reach the network"
  end

  test "a cached term costs no budget" do
    # The budget is checked AFTER the cache read on purpose: a cached term makes
    # no outbound call, so spending budget on it would throttle the app for
    # requests it never actually made.
    calls = 0
    with_cache_and_rps(1) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { calls += 1; [ PLACE ] }) do
        assert NominatimClient.search(query: "Austin").any?      # spends the budget
        assert NominatimClient.search(query: "Austin").any?      # served from cache
        assert NominatimClient.search(query: "Austin").any?
      end
    end
    assert_equal 1, calls
  end

  test "being over budget degrades to no suggestions rather than raising" do
    with_cache_and_rps(1) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { [ PLACE ] }) do
        NominatimClient.search(query: "Austin")
        assert_nothing_raised { NominatimClient.search(query: "Denver") }
        assert_equal [], NominatimClient.search(query: "Seattle")
      end
    end
  end

  test "an over-budget skip is not cached as an empty result" do
    # A skipped search must not poison the term for a full day — the existing
    # "only cache a real hit" rule is what protects this, so pin it.
    with_cache_and_rps(1) do
      stub_method(NominatimClient, :get_json, ->(_u, _p) { [ PLACE ] }) do
        NominatimClient.search(query: "Austin")
        assert_equal [], NominatimClient.search(query: "Lisbon")
      end
      # A later second, budget refreshed: the term resolves properly.
      travel 2.seconds
      SolidCache::Entry.delete_all
      stub_method(NominatimClient, :get_json, ->(_u, _p) { [ PLACE ] }) do
        assert NominatimClient.search(query: "Lisbon").any?,
               "the skipped term must not have been cached empty"
      end
    end
  end
end
