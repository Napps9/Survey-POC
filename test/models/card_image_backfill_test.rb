require "test_helper"

# The one-off conversion of decks that still carry inline base64 card imagery.
class CardImageBackfillTest < ActiveSupport::TestCase
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze
  PNG_DATA_URL = "data:image/png;base64,#{Base64.strict_encode64(PNG_BYTES)}".freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "bf-#{SecureRandom.hex(3)}")
  end

  def survey_with(cards, background: nil)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards,
                         background_image: background)
  end

  test "converts a card image, an option image and the background" do
    survey = survey_with(
      [ { "type" => "yes_no", "cid" => "c_a", "text" => "Q", "options" => [ "Yes", "No" ],
          "image" => PNG_DATA_URL },
        { "type" => "tap_card", "cid" => "c_b", "text" => "T", "options" => [ "S1" ],
          "option_images" => [ PNG_DATA_URL ] } ],
      background: PNG_DATA_URL
    )

    result = Survey::CardImageBackfill.run
    assert_equal 3, result.converted
    assert_equal 0, result.failed

    survey.reload
    assert survey.cards[0]["image"].start_with?("/rails/active_storage/")
    assert survey.cards[1]["option_images"][0].start_with?("/rails/active_storage/")
    assert survey.read_attribute(:background_image).start_with?("/rails/active_storage/")
    assert_not_includes survey.cards.to_json, "data:image/"
  end

  test "converted paths survive sanitize, so the images still render" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                             "options" => [ "Yes", "No" ], "image" => PNG_DATA_URL } ])
    Survey::CardImageBackfill.run

    url = survey.reload.cards.first["image"]
    assert_equal url, Survey.sanitize_image_url(url)
  end

  test "is idempotent — a second pass has nothing to do" do
    survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                    "options" => [ "Yes", "No" ], "image" => PNG_DATA_URL } ])

    assert_equal 1, Survey::CardImageBackfill.run.converted
    second = Survey::CardImageBackfill.run
    assert_equal 0, second.converted
    assert_equal 1, second.skipped
  end

  test "leaves decks with no inline images untouched" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                             "options" => [ "Yes", "No" ],
                             "image" => "https://images.pexels.com/photos/1/x.jpg" } ])
    before = survey.cards.to_json

    result = Survey::CardImageBackfill.run
    assert_equal 0, result.converted
    assert_equal 1, result.skipped
    assert_equal before, survey.reload.cards.to_json
  end

  test "a dry run reports without writing anything" do
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                             "options" => [ "Yes", "No" ], "image" => PNG_DATA_URL } ])

    result = Survey::CardImageBackfill.run(dry_run: true)
    assert_equal 1, result.converted
    assert result.freed_bytes.positive?
    assert_equal PNG_DATA_URL, survey.reload.cards.first["image"], "dry run must not write"
    assert_equal 0, survey.card_images.attachments.size
  end

  test "an undecodable image is left alone rather than blanked" do
    # A broken image is far worse than a fat one, so a failed conversion must
    # leave the original in place.
    junk   = "data:image/png;base64,!!!not-base64!!!"
    survey = survey_with([ { "type" => "yes_no", "cid" => "c_a", "text" => "Q",
                             "options" => [ "Yes", "No" ], "image" => junk } ])

    result = Survey::CardImageBackfill.run
    assert_equal 0, result.converted
    assert_equal 1, result.failed
    assert_equal junk, survey.reload.cards.first["image"]
  end

  test "a published Verto's options are not reshaped by the conversion" do
    # update_columns is used precisely so the range-scale normalisation can't
    # fire here — a live Verto's stored answers are indexes into its options.
    survey = survey_with([ { "type" => "range", "cid" => "c_r", "text" => "Q",
                             "options" => [ "Low", "Mid", "High" ], "image" => PNG_DATA_URL } ])
    survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    before_options = survey.reload.cards.first["options"]

    Survey::CardImageBackfill.run

    assert_equal before_options, survey.reload.cards.first["options"]
    assert survey.cards.first["image"].start_with?("/rails/active_storage/")
  end
end
