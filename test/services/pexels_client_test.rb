require "test_helper"

class PexelsClientTest < ActiveSupport::TestCase
  PHOTO = {
    "id"           => 123,
    "photographer" => "Jane Doe",
    "alt"          => "a mountain range",
    "src"          => {
      "original"  => "https://images.pexels.com/photos/123/p.jpg",
      "landscape" => "https://images.pexels.com/photos/123/p.jpg?w=1200&h=627&fit=crop",
      "portrait"  => "https://images.pexels.com/photos/123/p.jpg?w=800&h=1200&fit=crop",
      "tiny"      => "https://images.pexels.com/photos/123/p.jpg?w=280&h=200&fit=crop"
    }
  }.freeze

  test "url_for picks the slot-appropriate crop" do
    assert_equal PHOTO["src"]["landscape"], PexelsClient.url_for(PHOTO, :background)
    assert_equal PHOTO["src"]["portrait"],  PexelsClient.url_for(PHOTO, :card)
    assert_equal PHOTO["src"]["landscape"], PexelsClient.url_for(PHOTO, :swipe)
  end

  test "url_for falls back to original when the crop is missing" do
    photo = { "src" => { "original" => "https://images.pexels.com/photos/1/o.jpg" } }
    assert_equal "https://images.pexels.com/photos/1/o.jpg", PexelsClient.url_for(photo, :card)
  end

  test "configured? reads either env var" do
    with_env("PEXELS" => nil, "PEXELS_API_KEY" => nil) { assert_not PexelsClient.configured? }
    with_env("PEXELS" => "abc", "PEXELS_API_KEY" => nil) { assert PexelsClient.configured? }
    with_env("PEXELS" => nil, "PEXELS_API_KEY" => "abc") { assert PexelsClient.configured? }
  end

  test "search returns the photos array from the API body" do
    client = PexelsClient.new(api_key: "x")
    stub_method(client, :get_json, ->(_url, _params) { { "photos" => [ PHOTO ] } }) do
      photos = client.search(query: "mountains", orientation: "landscape")
      assert_equal 1, photos.size
      assert_equal 123, photos.first["id"]
    end
  end

  test "search returns [] with no key, blank query, or on error" do
    assert_equal [], PexelsClient.new(api_key: nil).search(query: "x")
    assert_equal [], PexelsClient.new(api_key: "x").search(query: "  ")

    client = PexelsClient.new(api_key: "x")
    stub_method(client, :get_json, ->(_u, _p) { raise "boom" }) do
      assert_equal [], client.search(query: "x")
    end
  end

  private

  def with_env(vars)
    old = vars.transform_values { |_| nil }
    vars.each { |k, v| old[k] = ENV[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
