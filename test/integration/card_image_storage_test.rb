require "test_helper"

# Card imagery is stored in Active Storage and referenced by a short path,
# instead of sitting inline in the cards JSON as multi-MB base64 — the
# acknowledged memory driver behind the production 502s (P1-7).
class CardImageStorageTest < ActionDispatch::IntegrationTest
  # A real 1x1 PNG, so Active Storage has genuine bytes to analyse.
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze
  PNG_DATA_URL = "data:image/png;base64,#{Base64.strict_encode64(PNG_BYTES)}".freeze

  def setup
    @org  = Organisation.create!(name: "O", slug: "img-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "U", email_address: "img-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => [ "Yes", "No" ] } ]
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def post_image(survey = @survey, image: PNG_DATA_URL)
    post card_image_survey_path(survey), params: { image: image }.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    JSON.parse(response.body)
  end

  test "an uploaded image is stored and returns a path the card can hold" do
    body = post_image
    assert_response :success
    assert body["ok"]

    url = body["url"]
    assert url.start_with?("/rails/active_storage/"), "expected a same-origin blob path, got #{url.inspect}"
    assert_equal 1, @survey.reload.card_images.attachments.size
  end

  test "the returned path survives sanitize, so it actually sticks on a card" do
    # The regression this guards: a blob path whose filename has no image
    # extension is silently dropped by sanitize_image_url, and the creator's
    # picture vanishes on the next autosave with no error anywhere.
    url = post_image["url"]
    assert_equal url, Survey.sanitize_image_url(url)

    patch survey_path(@survey),
          params: { cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                               "options" => [ "Yes", "No" ], "image" => url } ] }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success
    assert_equal url, @survey.reload.cards.first["image"]
  end

  test "the stored card no longer carries base64" do
    url = post_image["url"]
    patch survey_path(@survey),
          params: { cards: [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                               "options" => [ "Yes", "No" ], "image" => url } ] }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_not_includes @survey.reload.cards.to_json, "data:image/"
  end

  test "a non-image, an unsupported type and junk are all refused" do
    [ "https://example.com/photo.png", "data:text/html;base64,PGI+", "data:image/tiff;base64,AAAA", "nonsense" ].each do |bad|
      assert_nil Survey::CardImageStore.decode(bad), "#{bad.inspect} should not decode"
    end
    assert_response :success # setup's sign-in; nothing above hits the network
  end

  test "an image over the size cap is refused rather than stored" do
    oversized = "data:image/png;base64,#{Base64.strict_encode64('x' * (Survey::CARD_IMAGE_MAX_BYTES + 1))}"
    body = post_image(image: oversized)
    assert_response :unprocessable_entity
    assert_not body["ok"]
    assert_equal 0, @survey.reload.card_images.attachments.size
  end

  test "a published Verto is locked, matching every other editing path" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    post_image
    assert_response :locked
  end

  test "another organisation's Verto is unreachable" do
    other = Organisation.create!(name: "Other", slug: "img-other-#{SecureRandom.hex(3)}")
    theirs = other.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ], cards: [])
    post card_image_survey_path(theirs), params: { image: PNG_DATA_URL }.to_json,
         headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :not_found
  end

  test "card_images purge with the Verto rather than leaking blobs" do
    post_image
    assert_equal 1, @survey.reload.card_images.attachments.size

    assert_difference -> { ActiveStorage::Attachment.count }, -1 do
      @survey.destroy
    end
  end

  test "decode accepts every supported content type" do
    Survey::CARD_IMAGE_CONTENT_TYPES.each do |type|
      url = "data:#{type};base64,#{Base64.strict_encode64(PNG_BYTES)}"
      bytes, content_type = Survey::CardImageStore.decode(url)
      assert_equal PNG_BYTES, bytes
      assert_equal type, content_type
    end
  end

  test "data_url? distinguishes inline base64 from a stored path" do
    assert Survey::CardImageStore.data_url?(PNG_DATA_URL)
    assert_not Survey::CardImageStore.data_url?("/rails/active_storage/blobs/redirect/abc/card.png")
    assert_not Survey::CardImageStore.data_url?(nil)
  end
end
