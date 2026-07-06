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
end
