require "test_helper"

class NominatimGeocodeClientTest < ActiveSupport::TestCase
  PLACE = { "lat" => "30.267153", "lon" => "-97.7430608" }.freeze

  test "coordinates_for resolves lat/lng from Nominatim" do
    with_stubbed_geocode([ PLACE ]) do
      coords = NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
      assert_equal 30.267153, coords[:lat]
      assert_equal(-97.7430608, coords[:lng])
    end
  end

  test "coordinates_for passes countrycodes when a country_code is given" do
    seen_params = nil
    with_stubbed_geocode(->(_url, params) { seen_params = params; [ PLACE ] }) do
      NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}", country_code: "US")
    end
    assert_equal "us", seen_params[:countrycodes]
  end

  test "coordinates_for returns nil for a blank query without hitting the network" do
    with_stubbed_geocode(->(_u, _p) { raise "should not be called" }) do
      assert_nil NominatimGeocodeClient.coordinates_for(query: "")
      assert_nil NominatimGeocodeClient.coordinates_for(query: "   ")
    end
  end

  test "coordinates_for returns nil and never raises on error" do
    with_stubbed_geocode(->(_u, _p) { raise "boom" }) do
      assert_nil NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
    end
  end

  test "coordinates_for returns nil when Nominatim has no match" do
    with_stubbed_geocode([]) do
      assert_nil NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
    end
  end

  private

  # Stubs both the HTTP seam and the rate-limit sleep (so tests never
  # actually pause) for the duration of the block.
  def with_stubbed_geocode(result)
    impl = result.respond_to?(:call) ? result : ->(_url, _params) { result }
    stub_method(NominatimGeocodeClient, :throttle!, -> { }) do
      stub_method(NominatimGeocodeClient, :get_json, impl) { yield }
    end
  end
end
