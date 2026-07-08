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

  test "coordinates_for passes countrycodes and the polygon params when a country_code is given" do
    seen_params = nil
    with_stubbed_geocode(->(_url, params) { seen_params = params; [ PLACE ] }) do
      NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}", country_code: "US")
    end
    assert_equal "us", seen_params[:countrycodes]
    assert_equal 1, seen_params[:polygon_geojson]
    assert_equal NominatimGeocodeClient::POLYGON_THRESHOLD, seen_params[:polygon_threshold]
  end

  test "coordinates_for includes a simplified boundary when Nominatim returns polygon geojson" do
    place = PLACE.merge("geojson" => {
      "type" => "Polygon",
      "coordinates" => [ [ [ -97.8, 30.1 ], [ -97.6, 30.1 ], [ -97.6, 30.4 ], [ -97.8, 30.4 ], [ -97.8, 30.1 ] ] ]
    })
    with_stubbed_geocode([ place ]) do
      coords = NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
      assert_equal [ [ [ -97.8, 30.1 ], [ -97.6, 30.1 ], [ -97.6, 30.4 ], [ -97.8, 30.4 ], [ -97.8, 30.1 ] ] ], coords[:boundary]
    end
  end

  test "coordinates_for collects every outer ring of a MultiPolygon, dropping holes" do
    place = PLACE.merge("geojson" => {
      "type" => "MultiPolygon",
      "coordinates" => [
        [ [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 0, 0 ] ], [ [ 0.2, 0.2 ], [ 0.3, 0.2 ], [ 0.3, 0.3 ], [ 0.2, 0.2 ] ] ],
        [ [ [ 5, 5 ], [ 6, 5 ], [ 6, 6 ], [ 5, 5 ] ] ]
      ]
    })
    with_stubbed_geocode([ place ]) do
      coords = NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
      assert_equal 2, coords[:boundary].size
      assert_equal [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 0, 0 ] ], coords[:boundary].first
    end
  end

  test "coordinates_for omits boundary when Nominatim has no geojson for the match" do
    with_stubbed_geocode([ PLACE ]) do
      coords = NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
      refute coords.key?(:boundary)
    end
  end

  test "coordinates_for omits boundary for a non-polygon geometry" do
    place = PLACE.merge("geojson" => { "type" => "Point", "coordinates" => [ -97.74, 30.27 ] })
    with_stubbed_geocode([ place ]) do
      coords = NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
      refute coords.key?(:boundary)
    end
  end

  test "coordinates_for drops an oversized boundary rather than shipping a huge payload" do
    huge_ring = Array.new(NominatimGeocodeClient::MAX_BOUNDARY_VERTICES + 1) { |i| [ i * 0.001, i * 0.001 ] }
    place = PLACE.merge("geojson" => { "type" => "Polygon", "coordinates" => [ huge_ring ] })
    with_stubbed_geocode([ place ]) do
      coords = NominatimGeocodeClient.coordinates_for(query: "unique-#{SecureRandom.hex(4)}")
      refute coords.key?(:boundary)
      assert coords.key?(:lat)
    end
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
