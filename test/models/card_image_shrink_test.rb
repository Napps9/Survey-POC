require "test_helper"

# Inline card images too large for the store: CardImageBackfill leaves them,
# the sanitiser drops them on the deck's next editor save, and until then every
# render carries them. Fixtures plant the base64 with update_columns, as
# CardImageBackfillTest does, because a deck saved normally can't hold it.
#
# The resize itself is libvips, which this runner may not have — every test
# but the last injects a stand-in, and the last skips without the library.
class CardImageShrinkTest < ActiveSupport::TestCase
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze
  SMALL_INLINE = "data:image/png;base64,#{Base64.strict_encode64(PNG_BYTES)}".freeze
  # What a raw camera photo looks like in the column: over the sanitiser's cap,
  # so the backfill refuses it and the next save drops it.
  OVERSIZED = "data:image/jpeg;base64,#{Base64.strict_encode64(PNG_BYTES + ("\0" * Survey::MAX_BACKGROUND_DATA_URL_BYTES))}".freeze
  PEXELS_URL = "https://images.pexels.com/photos/1/x.jpg".freeze

  # Stands in for libvips: the shrunk "JPEG" is a tag carrying the input size.
  FAKE_RESIZE = ->(bytes) { [ "shrunk:#{bytes.bytesize}", 1600, 1200 ] }

  def setup
    @org = Organisation.create!(name: "O", slug: "sh-#{SecureRandom.hex(3)}")
  end

  def survey_with(cards)
    survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ], cards: [])
    survey.update_columns(cards: cards)
    survey.reload
  end

  def deck
    [ { "type" => "welcome_card", "cid" => "c_w", "text" => "Hello" },
      { "type" => "yes_no", "cid" => "c_big", "text" => "Q", "options" => [ "Yes", "No" ], "image" => OVERSIZED },
      { "type" => "yes_no", "cid" => "c_ok", "text" => "Q2", "options" => [ "Yes", "No" ], "image" => PEXELS_URL } ]
  end

  test "candidates are the inline images over the cap, and nothing else" do
    big   = survey_with(deck)
    survey_with([ { "type" => "yes_no", "cid" => "c_s", "text" => "Q", "options" => [ "Y", "N" ], "image" => SMALL_INLINE },
                  { "type" => "yes_no", "cid" => "c_p", "text" => "Q", "options" => [ "Y", "N" ], "image" => PEXELS_URL } ])

    found = Survey::CardImageShrink.candidates
    assert_equal [ [ big.id, "c_big", OVERSIZED.bytesize ] ], found.map { |c| [ c.survey_id, c.cid, c.bytes ] },
                 "a small inline image is the backfill's job, and a path is nobody's"
  end

  test "shrink! stores the resized image and swaps the card's value for the path" do
    survey = survey_with(deck)
    was_at = survey.updated_at

    result = Survey::CardImageShrink.shrink!(survey.id, "c_big", resize: FAKE_RESIZE)

    cards = survey.reload.cards
    assert_equal %w[c_w c_big c_ok], cards.map { |c| c["cid"] }, "card order is untouched"
    path = cards[1]["image"]
    assert path.start_with?("/rails/active_storage/"), "the card now carries a stored path, got #{path[0, 40]}"
    assert_equal path, Survey.sanitize_image_url(path), "the path survives the sanitiser, so the image renders"
    assert_equal deck[2], cards[2], "the neighbouring card is byte-for-byte what it was"
    assert_not_includes cards.to_json, "data:image/"

    blob = survey.card_images.attachments.sole.blob
    assert_equal "image/jpeg", blob.content_type
    assert_equal "shrunk:#{PNG_BYTES.bytesize + Survey::MAX_BACKGROUND_DATA_URL_BYTES}".bytesize, blob.byte_size,
                 "what was stored is what the resizer returned, built from the decoded original"

    assert_equal [ survey.id, "c_big", OVERSIZED.bytesize, blob.byte_size, 1600, 1200, path ],
                 [ result.survey_id, result.cid, result.before_bytes, result.after_bytes,
                   result.width, result.height, result.path ]
    assert_operator survey.updated_at, :>, was_at, "updated_at moves, so the cached play page is replaced"
    assert_empty Survey::CardImageShrink.candidates, "a converted card is no longer a candidate"
  end

  test "a published Verto's options are not reshaped by the conversion" do
    # update_all is used precisely so the range-scale normalisation can't fire —
    # a live Verto's stored answers are indexes into its options.
    survey = survey_with([ { "type" => "range", "cid" => "c_r", "text" => "Q",
                             "options" => [ "Low", "Mid", "High" ], "image" => OVERSIZED } ])
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)

    Survey::CardImageShrink.shrink!(survey.id, "c_r", resize: FAKE_RESIZE)

    card = survey.reload.cards.first
    assert_equal [ "Low", "Mid", "High" ], card["options"]
    assert card["image"].start_with?("/rails/active_storage/")
  end

  test "shrink! refuses a missing card or a card whose image is not inline, and writes nothing" do
    survey = survey_with(deck)
    before = survey.cards.to_json

    assert_raises(ArgumentError) { Survey::CardImageShrink.shrink!(survey.id, "c_nope", resize: FAKE_RESIZE) }
    assert_raises(ArgumentError) { Survey::CardImageShrink.shrink!(survey.id, "c_ok", resize: FAKE_RESIZE) }

    assert_equal before, survey.reload.cards.to_json
    assert_equal 0, survey.card_images.attachments.size
  end

  test "libvips shrinks to the browser's upload size and never enlarges" do
    begin
      require "vips"
    rescue LoadError
      skip "libvips is not installed on this runner (the production image ships it)"
    end

    tall  = Vips::Image.gaussnoise(900, 2400).cast("uchar").write_to_buffer(".jpg", Q: 90)
    small = Vips::Image.gaussnoise(300, 200).cast("uchar").write_to_buffer(".jpg", Q: 90)

    jpeg, width, height = Survey::CardImageShrink.resize_with_vips(tall)
    assert_equal [ 600, 1600 ], [ width, height ], "the longest side lands on MAX_EDGE"
    assert_equal [ 600, 1600 ], [ Vips::Image.new_from_buffer(jpeg, "").width, Vips::Image.new_from_buffer(jpeg, "").height ]
    assert_operator jpeg.bytesize, :<, tall.bytesize

    _, width, height = Survey::CardImageShrink.resize_with_vips(small)
    assert_equal [ 300, 200 ], [ width, height ], "a small picture keeps its pixels"
  end
end
