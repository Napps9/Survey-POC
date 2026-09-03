require "test_helper"

# A Range card is always a 5-point scale (Survey::RANGE_POINTS). An even count
# has no true centre, so someone who genuinely sits in the middle is forced to
# lean; a deck mixing 3-, 4- and 5-point sliders also can't be read card to
# card. The AI prompts ask for 5, but a model can drift and the importers map
# whatever the source form used — so the count is enforced on save.
class SurveyRangeScaleTest < ActiveSupport::TestCase
  def org
    @org ||= Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
  end

  def survey_with(cards, published: false)
    attrs = { title: "T", theme: "T", audience_age: "all", key_insight: "x",
              default_locale: "en", locales: [ "en" ], cards: cards }
    if published
      attrs[:publish_token] = SecureRandom.urlsafe_base64(18)
      attrs[:published_at]  = Time.current
    end
    org.surveys.create!(attrs)
  end

  def range(options)
    { "type" => "range", "text" => "How much?", "options" => options }
  end

  # ── normalize_range_labels ────────────────────────────────────────────────

  test "every shape of input comes out as exactly five labels" do
    [
      %w[SD D N A SA],
      %w[SD D A SA],
      [ "Never", "Sometimes", "Always" ],
      [ "Easy", "Hard" ],
      [ "Only" ],
      [],
      %w[1 2 3 4],
      %w[1 2 3 4 5 6 7],
      %w[a b c d e f g],
      [ "A", "", "", "", "E" ],
      [ nil, "  ", "Low" ]
    ].each do |input|
      assert_equal Survey::RANGE_POINTS, Survey.normalize_range_labels(input).size,
        "#{input.inspect} did not normalise to #{Survey::RANGE_POINTS} labels"
    end
  end

  test "a five-point scale is left exactly as written" do
    labels = [ "Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree" ]
    assert_equal labels, Survey.normalize_range_labels(labels)
  end

  test "a four-point scale keeps all four labels and gains the centre it lacked" do
    assert_equal [ "SD", "D", "Neutral", "A", "SA" ],
                 Survey.normalize_range_labels(%w[SD D A SA])
  end

  test "endpoints stay endpoints when a short scale is spread over five stops" do
    assert_equal [ "Never", "Disagree", "Sometimes", "Agree", "Always" ],
                 Survey.normalize_range_labels([ "Never", "Sometimes", "Always" ])
    out = Survey.normalize_range_labels([ "Easy", "Hard" ])
    assert_equal "Easy", out.first
    assert_equal "Hard", out.last
  end

  # No stop may be left nameless: the card would render a gap on the track, and
  # the editor's autosave would then drop it and shorten the scale again.
  test "no stop is ever left unlabelled" do
    [ %w[SD D A SA], [ "Easy", "Hard" ], [ "Only" ], %w[2 5 9], [ "A", "", "C", "D", "E" ] ].each do |input|
      out = Survey.normalize_range_labels(input)
      assert out.all?(&:present?), "#{input.inspect} left a blank stop: #{out.inspect}"
    end
  end

  # Clearing one label in the editor must name that stop again, not re-spread
  # the scale and shuffle every label after it.
  test "an already-five-point scale keeps every label exactly where it is" do
    assert_equal [ "A", "B", "Neutral", "D", "E" ],
                 Survey.normalize_range_labels([ "A", "B", "", "D", "E" ])
    assert_equal [ "A", "Disagree", "C", "D", "E" ],
                 Survey.normalize_range_labels([ "A", "", "C", "D", "E" ])
  end

  test "a card with no labels at all falls back to the default agree scale" do
    assert_equal Survey::RANGE_DEFAULT_LABELS, Survey.normalize_range_labels([])
  end

  test "a consecutive numeric scale keeps counting instead of gaining a word" do
    assert_equal %w[1 2 3 4 5], Survey.normalize_range_labels(%w[1 2 3 4])
    assert_equal %w[0 1 2 3 4], Survey.normalize_range_labels(%w[0 1 2 3])
    assert_equal %w[1 2 3 4 5], Survey.normalize_range_labels(%w[1 2 3 4 5 6 7])
  end

  test "a non-consecutive numeric scale is treated as words, not a run" do
    out = Survey.normalize_range_labels(%w[2 5 9])
    assert_equal %w[2 5 9], out.values_at(0, 2, 4)
  end

  test "more labels than points are sampled evenly, keeping both endpoints" do
    out = Survey.normalize_range_labels(%w[a b c d e f g])
    assert_equal "a", out.first
    assert_equal "g", out.last
    assert_equal out.uniq, out, "sampling must not duplicate a label"
  end

  test "normalising is idempotent, so a resaved card never drifts" do
    [ %w[SD D A SA], [ "Never", "Sometimes", "Always" ], %w[1 2 3 4],
      %w[a b c d e f g], [ "Easy", "Hard" ], [] ].each do |input|
      once  = Survey.normalize_range_labels(input)
      twice = Survey.normalize_range_labels(once)
      assert_equal once, twice, "#{input.inspect} is not stable under re-normalising"
    end
  end

  # ── normalize_range_cards! ────────────────────────────────────────────────

  test "only range cards are touched" do
    others = [
      { "type" => "multiple_choice", "options" => %w[a b c] },
      { "type" => "nps",             "options" => (0..10).map(&:to_s) },
      { "type" => "rating",          "options" => %w[Poor Great] },
      { "type" => "welcome_card" }
    ]
    assert_equal others, Survey.normalize_range_cards!(others)
  end

  test "translations are resized alongside the primary scale, falling back to it" do
    card = { "type" => "range", "options" => %w[SD D A SA],
             "i18n" => { "fr" => { "options" => %w[Pas Peu] } } }
    out = Survey.normalize_range_cards!([ card ]).first
    assert_equal Survey::RANGE_POINTS, out["options"].size
    assert_equal Survey::RANGE_POINTS, out["i18n"]["fr"]["options"].size
    # The translated endpoints survive; the untranslated stops fall through to
    # the primary language rather than rendering blank.
    assert_equal "Pas", out["i18n"]["fr"]["options"].first
    assert_equal "Peu", out["i18n"]["fr"]["options"].last
  end

  test "a translation with no options key is left alone" do
    card = { "type" => "range", "options" => %w[SD D A SA],
             "i18n" => { "fr" => { "text" => "Combien ?" } } }
    out = Survey.normalize_range_cards!([ card ]).first
    assert_equal({ "text" => "Combien ?" }, out["i18n"]["fr"])
  end

  test "non-hash cards pass through untouched" do
    assert_equal [ nil, "junk" ], Survey.normalize_range_cards!([ nil, "junk" ])
  end

  # ── enforced on save ──────────────────────────────────────────────────────

  test "a range card saved with four points is stored with five" do
    s = survey_with([ range(%w[SD D A SA]) ])
    assert_equal Survey::RANGE_POINTS, s.reload.cards[0]["options"].size
  end

  test "enforcement covers every creation path, not just the editor" do
    s = survey_with([ range(%w[Low High]), range(%w[1 2 3 4]), range([]) ])
    s.reload.cards.each_with_index do |c, i|
      assert_equal Survey::RANGE_POINTS, c["options"].size, "card #{i} kept a non-5 scale"
    end
  end

  test "a later update is normalised too" do
    s = survey_with([ range(%w[SD D N A SA]) ])
    s.update!(cards: [ range(%w[Yes Maybe No]) ])
    assert_equal Survey::RANGE_POINTS, s.reload.cards[0]["options"].size
  end

  # A stored answer is an INDEX into the scale it was collected on, so resizing
  # a live card's options would silently re-point every response already
  # gathered. Published Vertos are locked for editing anyway.
  test "a published Verto's scale is left alone so existing answers stay aligned" do
    s = survey_with([ range(%w[SD D A SA]) ], published: true)
    assert_equal 4, s.reload.cards[0]["options"].size
  end

  # Same invariant once the Verto is CLOSED (taken down after collecting
  # answers): the guard is editing_locked?, not published?, because an account
  # LiveEditAccess allows past the lock can save such a deck — and the answers
  # already stored against this card must not be re-pointed by a normaliser
  # touching a card the editor didn't.
  test "a closed Verto's scale is left alone too" do
    s = survey_with([ range(%w[SD D A SA]) ], published: true)
    s.responses.create!(session_token: SecureRandom.uuid, answers: { "0" => { "value" => 2 } },
                        answered: true, status: "completed")
    s.update!(unpublished_at: Time.current)
    assert s.closed?

    s.update!(cards: [ range(%w[SD D A SA]), { "type" => "open_ended", "text" => "Why?" } ])
    assert_equal 4, s.reload.cards[0]["options"].size
  end

  test "saving an unrelated attribute does not rewrite the cards" do
    s = survey_with([ range(%w[SD D N A SA]) ])
    before = s.reload.cards
    s.update!(title: "Renamed")
    assert_equal before, s.reload.cards
  end
end
