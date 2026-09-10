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

  # What this file is about is the page a RESPONDENT loads: every image their
  # browser fetches should come from the bucket rather than costing a Rails
  # request. The <head> is a different audience — og:image is read by link
  # crawlers, once, and deliberately does NOT follow this rule (see the last
  # test) — so the assertions below are scoped to the body.
  def rendered_body
    response.body.split("</head>", 2).last
  end

  test "on the local disk the page keeps the same-origin paths" do
    get play_survey_path(@survey.publish_token)

    assert_response :success
    assert_includes rendered_body, @redirect_path, "the card image is drawn from its redirect path"
    assert_includes rendered_body, "/rails/active_storage/blobs/proxy/", "the logo is proxied"
    refute_includes rendered_body, "/rails/active_storage/disk/"
  end

  test "on the bucket the page carries the blobs' own URLs for the card image and the logo" do
    stub_method(ObjectStorage, :bucket_active?, true) do
      get play_survey_path(@survey.publish_token)
    end

    assert_response :success
    refute_includes rendered_body, @redirect_path
    refute_includes rendered_body, "/rails/active_storage/blobs/proxy/"
    # The suite's "bucket" is the Disk service, whose own URL is the disk route.
    assert_includes rendered_body, "/rails/active_storage/disk/"
  end

  # og:image is the deliberate exception, and it is worth being explicit about
  # why rather than letting a future reader "fix" it to match the rest.
  #
  # A bucket URL is PRESIGNED and therefore expires. og:image is not fetched by
  # the respondent at all — it is fetched by WhatsApp, Slack, Facebook and the
  # rest, at some unknown time after the link was pasted, and re-fetched when
  # their cache lapses. Handing them a URL with a TTL means a preview that works
  # on Monday and 403s on Friday. The same-origin redirect path has no TTL and
  # 302s to a fresh presigned URL on every crawl, so it is the durable choice.
  #
  # It also costs nothing: this is one URL in a meta tag, fetched once per
  # unfurl, not one Rails request per image per respondent — which is the thing
  # PlayerAssetUrls exists to avoid.
  test "og:image keeps the durable redirect path even on the bucket" do
    stub_method(ObjectStorage, :bucket_active?, true) do
      get play_survey_path(@survey.publish_token)
    end

    src = css_select("meta[property='og:image']").first["content"]
    assert_includes src, @redirect_path,
                    "og:image must not carry an expiring presigned URL"
    refute_includes src, "/rails/active_storage/disk/"
  end
end
