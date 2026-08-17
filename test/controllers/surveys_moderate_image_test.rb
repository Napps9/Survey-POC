require "test_helper"

class SurveysModerateImageTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "m-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "mi-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(
      title: "S", theme: "Space", audience_age: "under 10s", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: []
    )
  end

  PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  # Returns a no-arg lambda so stub_method makes `ImageModerator.new` RETURN the
  # fake (the fake itself responds to :call, which stub_method would otherwise
  # treat as the impl to invoke).
  def returns_moderator(safe:, reason: "", ambiguous: false)
    fake = Object.new
    verdict = ambiguous ? { safe: safe, reason: reason, ambiguous: true } : { safe: safe, reason: reason }
    fake.define_singleton_method(:call) { |**_kw| verdict }
    -> { fake }
  end

  test "allows a safe upload" do
    stub_method(ImageModerator, :configured?, true) do
      stub_method(ImageModerator, :new, returns_moderator(safe: true)) do
        post moderate_image_survey_path(@survey), params: { image: PNG }, as: :json
      end
    end
    assert_response :success
    assert_equal true, JSON.parse(response.body)["ok"]
  end

  test "blocks an unsafe upload with the reason, and marks it appealable" do
    stub_method(ImageModerator, :configured?, true) do
      stub_method(ImageModerator, :new, returns_moderator(safe: false, reason: "shows alcohol")) do
        post moderate_image_survey_path(@survey), params: { image: PNG }, as: :json
      end
    end
    body = JSON.parse(response.body)
    assert_equal false, body["ok"]
    assert_equal "shows alcohol", body["reason"]
    assert_equal true, body["appealable"]
  end

  test "shows an honest couldn't-verify message for an ambiguous verdict, not the not-PG copy — also appealable" do
    stub_method(ImageModerator, :configured?, true) do
      stub_method(ImageModerator, :new, returns_moderator(safe: false, ambiguous: true)) do
        post moderate_image_survey_path(@survey), params: { image: PNG }, as: :json
      end
    end
    assert_response :bad_gateway
    body = JSON.parse(response.body)
    assert_equal false, body["ok"]
    assert_equal I18n.t("flash.surveys.image_unverified"), body["reason"]
    assert_equal true, body["appealable"]
  end

  test "allows through when moderation is unconfigured" do
    stub_method(ImageModerator, :configured?, false) do
      post moderate_image_survey_path(@survey), params: { image: PNG }, as: :json
    end
    assert_equal true, JSON.parse(response.body)["ok"]
  end

  test "rejects a non-image payload" do
    stub_method(ImageModerator, :configured?, true) do
      post moderate_image_survey_path(@survey), params: { image: "not-an-image" }, as: :json
    end
    assert_equal false, JSON.parse(response.body)["ok"]
  end

  test "another org's survey is not reachable" do
    other = Organisation.create!(name: "X", slug: "mi2-#{SecureRandom.hex(2)}")
    s2 = other.surveys.create!(title: "S2", theme: "t", audience_age: "all",
                               key_insight: "k", default_locale: "en", locales: [ "en" ], cards: [])
    post moderate_image_survey_path(s2), params: { image: PNG }, as: :json
    assert_response :not_found
  end
end
