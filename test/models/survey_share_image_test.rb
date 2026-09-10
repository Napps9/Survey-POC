require "test_helper"

# A shared /play link used to unfurl with no picture at all — the app emitted
# og:title and og:description and nothing else, so a Verto pasted into a group
# chat was a line of grey text next to everyone else's cards.
#
# The rule this file exists to hold is that there is ALWAYS a picture. Not
# "usually", not "when the creator uploaded something": a guarantee, because
# social recruitment is a real distribution channel and "it depends" is not
# something anyone can plan around. Survey#share_image_path therefore ends in a
# theme-matched picture from the committed library rather than in nil.
class SurveyShareImageTest < ActiveSupport::TestCase
  # A real 1x1 PNG, so externalize_inline_images has something it can actually
  # convert rather than failing its way into the fallback by accident.
  PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  def survey(**attrs)
    org = Organisation.create!(name: "SI", slug: "si-#{SecureRandom.hex(4)}")
    s = org.surveys.new({
      title: "T", theme: "community life", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: []
    }.merge(attrs))
    s.save!(validate: false)
    s
  end

  test "a Verto with no imagery at all still has a share image" do
    s = survey
    assert s.share_image_path.present?,
           "every Verto must unfurl with a picture — that is the whole point of the fallback"
    assert_match %r{verto-library/backgrounds/}, s.share_image_path
  end

  test "the Verto's own imagery wins over the library" do
    pexels = "https://images.pexels.com/photos/1234/example.jpg"
    assert_equal pexels, survey(background_image: pexels).share_image_path
    assert_equal pexels, survey(consent_image: pexels).share_image_path
  end

  test "consent imagery is preferred to the background" do
    s = survey(consent_image: "https://images.pexels.com/photos/1/consent.jpg",
               background_image: "https://images.pexels.com/photos/2/background.jpg")
    assert_match "consent.jpg", s.share_image_path
  end

  test "a card's own picture is used when the Verto has none" do
    card_image = "/rails/active_storage/blobs/redirect/abc123/photo.jpg"
    s = survey(cards: [
      { "type" => "welcome_card", "title" => "W" },
      { "type" => "yes_no", "text" => "Q", "media_bg" => { "image" => card_image } }
    ])
    assert_equal card_image, s.share_image_path
  end

  # An uploaded background normally never reaches this code as base64:
  # Survey#externalize_inline_images converts data: URLs to Active Storage
  # blobs on save, and the blob is a perfectly good og:image.
  test "an uploaded background is used, having been externalised on save" do
    s = survey(background_image: "data:image/png;base64,#{PNG_B64}")
    assert_match %r{/rails/active_storage/}, s.share_image_path,
                 "externalize_inline_images should have turned this into a blob"
  end

  # But that conversion is documented as deliberately forgiving — "a conversion
  # that fails leaves the data-URL alone" — so base64 CAN still be sitting in
  # the column. A crawler cannot fetch it, and emitting it would be a broken
  # og:image, which is worse than the library picture. update_columns to
  # reproduce the state the callback would have left behind.
  test "a data: URL that survived externalising is skipped, not emitted" do
    s = survey
    s.update_columns(background_image: "data:image/png;base64,#{PNG_B64}")
    path = s.reload.share_image_path
    refute_match(/\Adata:/, path, "base64 cannot be fetched by a crawler")
    assert_match %r{verto-library/backgrounds/}, path
  end

  test "a surviving data: URL still yields to a card's real picture" do
    card_image = "/rails/active_storage/blobs/redirect/xyz789/card.jpg"
    s = survey(cards: [ { "type" => "yes_no", "text" => "Q", "image" => card_image } ])
    s.update_columns(background_image: "data:image/png;base64,#{PNG_B64}")
    assert_equal card_image, s.reload.share_image_path
  end

  # The URL is cached by every chat app that has ever unfurled the link, so a
  # picture that changes between deploys means inconsistent previews for the
  # same URL. Ruby seeds String#hash per PROCESS, which is exactly how a
  # "stable per-survey choice" stops being stable — hence a digest.
  test "the fallback is the same picture every time, in any process" do
    s = survey
    first = s.share_image_path
    assert_equal first, s.share_image_path
    assert_equal first, Survey.find(s.id).share_image_path

    expected = AssetPopulator.share_image_url_for(s)
    assert_equal expected, first
    assert_equal expected, AssetPopulator.share_image_url_for(Survey.find(s.id))
  end

  # Not "fitness picks sport.jpg" — theme_keywords expands through the
  # manifest's clusters, so "fitness training" legitimately reaches `community`
  # and `team` as well and several backgrounds match. The property that
  # actually matters is that the picture chosen is one of the ones that MATCH,
  # rather than an arbitrary member of the pool.
  test "the fallback picks from the backgrounds whose themes match" do
    [ "fitness training", "climate action", "community life" ].each do |theme|
      s = survey(theme: theme)
      wanted = AssetPopulator.theme_keywords(theme)
      themed = Array(AssetPopulator.manifest["backgrounds"]).select do |a|
        (Array(a["themes"]).map { |t| t.to_s.downcase } & wanted).any?
      end
      next if themed.empty? # then any picture is as good as any other

      chosen = File.basename(s.share_image_path).split("-").first
      assert_includes themed.map { |a| File.basename(a["file"], ".*") }, chosen,
                      "#{theme.inspect} chose #{chosen}, which matches none of its themes"
    end
  end

  test "alt text names the Verto rather than the file" do
    assert_equal "community life · Playverto", survey.share_image_alt
  end

  # The chain's helpers are implementation, not API — the view calls
  # share_image_path and nothing else.
  test "the resolution helpers are private" do
    s = survey
    assert_raises(NoMethodError) { s.shareable_image?("x") }
    assert_raises(NoMethodError) { s.first_card_image }
  end
end
