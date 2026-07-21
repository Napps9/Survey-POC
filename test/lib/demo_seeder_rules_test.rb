require "test_helper"

# The demo decks are the shop window for the Rules of the Game — they must
# score green against the same rules the editor checks live. Guards the
# card-shape rules without touching the database (deck definitions only).
class DemoSeederRulesTest < ActiveSupport::TestCase
  NON_QUESTION = %w[welcome_card token_checkpoint].freeze

  def decks
    seeder = DemoSeeder.allocate
    {
      "money_matters"    => deck_cards(seeder, :build_money_matters!),
      "workplace"        => deck_cards(seeder, :build_workplace_culture!),
      "campus"           => deck_cards(seeder, :build_campus_wellness!),
      "community_safety" => deck_cards(seeder, :build_community_safety!)
    }
  end

  FakeSurvey = Struct.new(:cards)

  # Pull just the card array out of each builder — the deck literal after the
  # same DemographicQuestions.append_to the builders run — without touching
  # the database. Same singleton-override idiom as OptimiseCardTest.
  def deck_cards(seeder, builder)
    captured = nil
    Survey.define_singleton_method(:create!) { |**kwargs| captured = kwargs[:cards]; FakeSurvey.new(kwargs[:cards]) }
    seeder.define_singleton_method(:publish!) { |*| }
    seeder.define_singleton_method(:safe_slug) { |*| nil }
    seeder.send(builder)
    captured
  ensure
    Survey.singleton_class.remove_method(:create!)
  end

  test "every demo deck lands in the green 12-16 card band" do
    decks.each do |name, cards|
      assert_includes 12..16, cards.size, "#{name} deck has #{cards.size} cards"
    end
  end

  test "every demo nps card is the 0-10 (11-point) scale" do
    decks.each do |name, cards|
      cards.select { |c| c["type"] == "nps" }.each do |card|
        assert_equal (0..10).map(&:to_s), card["options"], "#{name}: #{card['text']}"
      end
    end
  end

  test "every demo tap card carries 5-8 statements within the 40-char budget" do
    decks.each do |name, cards|
      cards.select { |c| c["type"] == "tap_card" }.each do |card|
        opts = Array(card["options"])
        assert_includes 5..8, opts.size, "#{name}: #{card['text']}"
        opts.each { |o| assert o.length <= 40, "#{name}: statement over 40 chars: #{o.inspect}" }
        # Quiz tap cards must grade/award every statement they show.
        assert_equal opts.sort, card["correct"].keys.sort, "#{name}: correct map matches statements" if card["correct"].is_a?(Hash)
        assert_equal opts.sort, card["tokens"].keys.sort, "#{name}: tokens map matches statements" if card["tokens"].is_a?(Hash)
      end
    end
  end

  test "every demo scenario card carries 1-5 pages and 2-3 options" do
    decks.each do |name, cards|
      cards.select { |c| c["type"] == "scenario" }.each do |card|
        pages = Array(card["pages"])
        opts  = Array(card["options"])
        assert_includes 1..5, pages.size, "#{name}: #{card['text']}"
        pages.each { |p| assert p["text"].length <= 400, "#{name}: page over 400 chars: #{p['text'].inspect}" }
        assert_includes 2..3, opts.size, "#{name}: #{card['text']} has #{opts.size} options"
        # Quiz scenario cards must grade/award against an option that's actually on the page.
        assert_includes opts, card["correct"], "#{name}: correct answer matches an option" if card["correct"].present?
        assert (Array(card["tokens"].keys) - opts).empty?, "#{name}: tokens map matches options" if card["tokens"].is_a?(Hash)
      end
    end
  end

  test "every demo image-list card has an odd 3-5 option count" do
    decks.each do |name, cards|
      cards.select { |c| %w[multiple_choice select_many].include?(c["type"]) }.each do |card|
        n = Array(card["options"]).size
        assert_includes [ 3, 5 ], n, "#{name}: #{card['text']} has #{n} options"
      end
    end
  end

  test "no demo deck runs the same answer type more than twice in a row" do
    decks.each do |name, cards|
      types = cards.reject { |c| NON_QUESTION.include?(c["type"]) }.map { |c| c["type"] }
      run = types.each_cons(3).find { |a, b, c| a == b && b == c }
      assert_nil run, "#{name}: #{run&.first} appears 3+ times in a row"
    end
  end
end
