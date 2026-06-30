require "test_helper"

class SurveysPexelsSearchTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "px-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(
      title: "S", theme: "Mountains", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: []
    )
  end

  def fake_client(photos, videos = [])
    fake = Object.new
    fake.define_singleton_method(:search) { |**_kw| photos }
    fake.define_singleton_method(:search_videos) { |**_kw| videos }
    fake
  end

  PHOTO = {
    "id" => 7, "photographer" => "Jane", "photographer_url" => "https://www.pexels.com/@jane", "alt" => "peak",
    "src" => {
      "original" => "https://images.pexels.com/photos/7/p.jpg",
      "tiny"     => "https://images.pexels.com/photos/7/p.jpg?w=280&h=200&fit=crop"
    }
  }.freeze

  VIDEO = {
    "id" => 88, "image" => "https://images.pexels.com/videos/88/poster.jpeg",
    "user" => { "name" => "Sam Reel", "url" => "https://www.pexels.com/@sam" },
    "video_files" => [
      { "file_type" => "video/mp4", "width" => 720, "link" => "https://videos.pexels.com/video-files/88/hd.mp4" }
    ]
  }.freeze

  test "returns landscape-cropped URLs for background context" do
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake_client([ PHOTO ])) do
        get pexels_search_survey_path(@survey), params: { q: "alps", context: "background" }
      end
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_match %r{w=1920&h=1080}, body["images"].first["url"]
    assert_equal PHOTO["src"]["tiny"], body["images"].first["thumb"]
  end

  test "returns portrait-cropped URLs for card context" do
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake_client([ PHOTO ])) do
        get pexels_search_survey_path(@survey), params: { q: "alps", context: "card" }
      end
    end
    body = JSON.parse(response.body)
    img  = body["images"].first
    assert_match %r{w=720&h=1280}, img["url"]
    assert_equal "Jane", img["photographer"]
    assert_equal "https://www.pexels.com/@jane", img["photographer_url"]
  end

  test "media=videos returns video items with the streamable mp4 + poster + credit" do
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake_client([], [ VIDEO ])) do
        get pexels_search_survey_path(@survey), params: { q: "running", context: "card", media: "videos" }
      end
    end
    assert_response :success
    item = JSON.parse(response.body)["images"].first
    assert_equal "video", item["type"]
    assert_equal "https://videos.pexels.com/video-files/88/hd.mp4", item["video"]
    assert_equal "https://images.pexels.com/videos/88/poster.jpeg", item["poster"]
    assert_equal "Sam Reel", item["photographer"]
    assert_equal "https://www.pexels.com/@sam", item["photographer_url"]
  end

  test "blank query returns empty list without calling Pexels" do
    get pexels_search_survey_path(@survey), params: { q: "  " }
    assert_response :success
    assert_equal [], JSON.parse(response.body)["images"]
  end

  test "reports search_unavailable when no key is configured" do
    stub_method(PexelsClient, :configured?, false) do
      get pexels_search_survey_path(@survey), params: { q: "alps" }
    end
    body = JSON.parse(response.body)
    assert_equal [], body["images"]
    assert_equal "search_unavailable", body["error"]
  end

  test "CSP allows Pexels images so picked/populated photos can render" do
    get survey_path(@survey)
    assert_response :success
    csp = response.headers["Content-Security-Policy"].to_s
    assert_includes csp, "images.pexels.com",
      "img-src must allow images.pexels.com or Pexels photos are blocked by the browser"
    assert_includes csp, "media-src",
      "a media-src directive is needed for card videos"
    assert_includes csp, "videos.pexels.com",
      "media-src must allow videos.pexels.com or Pexels videos are blocked by the browser"
  end
end
