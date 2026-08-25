require "test_helper"

# The share panel's QR code: rendered inline for scanning off a screen, and
# downloadable as an SVG (print) or PNG (slides and other tools that won't
# place an SVG). All encode the same public link, preferring a custom slug
# over the opaque publish_token.
class QrCodeTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "qr-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "qr-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def survey_for(org, slug: nil, published: true)
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS, slug: slug,
      publish_token: published ? SecureRandom.urlsafe_base64(18) : nil,
      published_at:  published ? Time.current : nil
    )
  end

  test "public_link_key prefers a custom slug and is nil until published" do
    org = sign_in_org("key")

    draft = survey_for(org, published: false)
    assert_nil draft.public_link_key, "a draft has no public link to encode"

    tokened = survey_for(org)
    assert_equal tokened.publish_token, tokened.public_link_key

    slugged = survey_for(org, slug: "summer-feedback")
    assert_equal "summer-feedback", slugged.public_link_key
  end

  test "the editor's share panel renders an inline QR for a published Verto" do
    org = sign_in_org("panel")
    s   = survey_for(org)

    get survey_path(s)
    assert_response :success
    assert_select "svg[viewBox]", minimum: 1
    assert_match "Download QR (PNG)", response.body
    assert_match "Download QR (SVG)", response.body
  end

  test "a draft's panel renders no QR and no download link" do
    org = sign_in_org("draft")
    s   = survey_for(org, published: false)

    get survey_path(s)
    assert_response :success
    assert_no_match "Download QR (", response.body
  end

  test "the qr endpoint sends a standalone SVG named after the public link" do
    org = sign_in_org("download")
    s   = survey_for(org, slug: "team-pulse")

    get qr_survey_path(s)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_match(/team-pulse-qr\.svg/, response.headers["Content-Disposition"])
    assert response.body.start_with?("<?xml"), "download should be a standalone SVG document"
  end

  test "the qr svg carries a quiet zone so it scans off a printed page" do
    org = sign_in_org("quiet")
    s   = survey_for(org)

    get qr_survey_path(s)
    # viewBox is the module grid plus the 4-module margin on each side, so it is
    # strictly larger than the grid alone — the guard against dropping `offset`.
    box = response.body[/viewBox="0 0 (\d+) \d+"/, 1].to_i
    assert box.positive?
    assert_equal 0, box % 4, "viewBox should be a whole number of 4px modules"
    assert box > 32, "viewBox should include the quiet-zone margin"
  end

  test "the qr endpoint sends a real PNG when asked for one" do
    org = sign_in_org("png")
    s   = survey_for(org, slug: "team-pulse")

    get qr_survey_path(s, format: :png)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_match(/team-pulse-qr\.png/, response.headers["Content-Disposition"])
    assert response.body.b.start_with?("\x89PNG\r\n\x1a\n".b), "download should be a PNG bytestream"
  end

  test "the qr png is print-sized, square, and keeps its quiet zone" do
    org = sign_in_org("pngsize")
    s   = survey_for(org)

    get qr_survey_path(s, format: :png)
    img = ChunkyPNG::Image.from_blob(response.body.b)
    assert_equal img.width, img.height, "QR canvas should be square"
    assert img.width >= 1024, "PNG should be large enough to print crisply"
    # The corner sits inside the quiet zone: opaque white, never transparent —
    # a transparent margin dies on dark slide decks.
    assert_equal ChunkyPNG::Color::WHITE, img[0, 0], "quiet zone should be opaque white"
    assert_equal ChunkyPNG::Color::WHITE, img[img.width - 1, img.height - 1]
  end

  test "the qr endpoint 404s for an unpublished draft" do
    org = sign_in_org("nodraft")
    s   = survey_for(org, published: false)

    get qr_survey_path(s)
    assert_response :not_found

    get qr_survey_path(s, format: :png)
    assert_response :not_found
  end

  test "another organisation's Verto is not reachable" do
    other_org = Organisation.create!(name: "Other", slug: "qr-other-#{SecureRandom.hex(2)}")
    theirs    = survey_for(other_org)

    sign_in_org("intruder")
    get qr_survey_path(theirs)
    assert_response :not_found
  end
end
