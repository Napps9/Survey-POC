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

  def fake_client(photos)
    fake = Object.new
    fake.define_singleton_method(:search) { |**_kw| photos }
    fake
  end

  PHOTO = {
    "id" => 7, "photographer" => "Jane", "alt" => "peak",
    "src" => {
      "landscape" => "https://images.pexels.com/photos/7/p.jpg?w=1200&h=627&fit=crop",
      "portrait"  => "https://images.pexels.com/photos/7/p.jpg?w=800&h=1200&fit=crop",
      "tiny"      => "https://images.pexels.com/photos/7/p.jpg?w=280&h=200&fit=crop"
    }
  }.freeze

  test "returns landscape URLs for background context" do
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake_client([ PHOTO ])) do
        get pexels_search_survey_path(@survey), params: { q: "alps", context: "background" }
      end
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal PHOTO["src"]["landscape"], body["images"].first["url"]
    assert_equal PHOTO["src"]["tiny"],      body["images"].first["thumb"]
  end

  test "returns portrait URLs for card context" do
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake_client([ PHOTO ])) do
        get pexels_search_survey_path(@survey), params: { q: "alps", context: "card" }
      end
    end
    body = JSON.parse(response.body)
    assert_equal PHOTO["src"]["portrait"], body["images"].first["url"]
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
  end
end
