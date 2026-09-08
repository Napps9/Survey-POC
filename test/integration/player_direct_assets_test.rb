require "test_helper"

# Once uploads live in the bucket, the public player draws card images and the
# organisation logo straight from object storage: the page carries the blobs'
# own URLs, not the same-origin redirect/proxy paths that cost a Rails request
# per image per respondent (PlayerAssetUrls). On the local disk the page is
# byte-for-byte what it always was.
class PlayerDirectAssetsTest < ActionDispatch::IntegrationTest
  setup do
    @org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(3)}")
    @org.logo.attach(io: StringIO.new("png"), filename: "logo.png", content_type: "image/png")
    @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("png"), filename: "card.png", content_type: "image/png")
    @redirect_path = Rails.application.routes.url_helpers.rails_blob_path(@blob, only_path: true)
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b], "image" => @redirect_path } ]
    )
    @survey.card_images.attach(@blob)
    @survey.update!(publish_token: SecureRandom.hex(8))
  end

  test "on the local disk the page keeps the same-origin paths" do
    get play_survey_path(@survey.publish_token)

    assert_response :success
    assert_includes response.body, @redirect_path, "the card image is drawn from its redirect path"
    assert_includes response.body, "/rails/active_storage/blobs/proxy/", "the logo is proxied"
    refute_includes response.body, "/rails/active_storage/disk/"
  end

  test "on the bucket the page carries the blobs' own URLs for the card image and the logo" do
    stub_method(ObjectStorage, :bucket_active?, true) do
      get play_survey_path(@survey.publish_token)
    end

    assert_response :success
    refute_includes response.body, @redirect_path
    refute_includes response.body, "/rails/active_storage/blobs/proxy/"
    # The suite's "bucket" is the Disk service, whose own URL is the disk route.
    assert_includes response.body, "/rails/active_storage/disk/"
  end
end
