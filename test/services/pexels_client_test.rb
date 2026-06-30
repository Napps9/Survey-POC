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

  test "url_for builds an exact crop per slot from the original" do
    base = PHOTO["src"]["original"]
    assert_equal "#{base}?auto=compress&cs=tinysrgb&fit=crop&w=1920&h=1080", PexelsClient.url_for(PHOTO, :background)
    assert_equal "#{base}?auto=compress&cs=tinysrgb&fit=crop&w=720&h=1280",  PexelsClient.url_for(PHOTO, :card)
    assert_equal "#{base}?auto=compress&cs=tinysrgb&fit=crop&w=800&h=800",   PexelsClient.url_for(PHOTO, :swipe)
  end

  test "url_for falls back to a pre-baked size when there's no original" do
    photo = { "src" => { "large" => "https://images.pexels.com/photos/1/l.jpg" } }
    assert_equal "https://images.pexels.com/photos/1/l.jpg", PexelsClient.url_for(photo, :card)
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

  VIDEO = {
    "id" => 9, "image" => "https://images.pexels.com/videos/9/poster.jpeg",
    "user" => { "name" => "Sam Reel", "url" => "https://www.pexels.com/@sam" },
    "video_files" => [
      { "file_type" => "video/mp4", "width" => 426,  "link" => "https://videos.pexels.com/video-files/9/tiny.mp4" },
      { "file_type" => "video/mp4", "width" => 720,  "link" => "https://videos.pexels.com/video-files/9/hd.mp4" },
      { "file_type" => "video/mp4", "width" => 3840, "link" => "https://videos.pexels.com/video-files/9/uhd.mp4" }
    ]
  }.freeze

  test "video_file_url picks the smallest mp4 at least 720px, never 4K" do
    assert_equal "https://videos.pexels.com/video-files/9/hd.mp4", PexelsClient.video_file_url(VIDEO)
  end

  test "video_file_url returns nil when there is no usable mp4" do
    assert_nil PexelsClient.video_file_url({ "video_files" => [ { "file_type" => "video/webm", "width" => 720, "link" => "x" } ] })
    assert_nil PexelsClient.video_file_url({})
  end

  test "video_poster and video_credit read the expected fields" do
    assert_equal "https://images.pexels.com/videos/9/poster.jpeg", PexelsClient.video_poster(VIDEO)
    assert_equal({ "name" => "Sam Reel", "url" => "https://www.pexels.com/@sam" }, PexelsClient.video_credit(VIDEO))
  end

  test "search_videos returns the videos array from the API body" do
    client = PexelsClient.new(api_key: "x")
    stub_method(client, :get_json, ->(_url, _params) { { "videos" => [ VIDEO ] } }) do
      vids = client.search_videos(query: "mountains", orientation: "portrait")
      assert_equal 1, vids.size
      assert_equal 9, vids.first["id"]
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
