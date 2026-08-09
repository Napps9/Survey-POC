require "test_helper"

# The deck registry, and the invariants every deck has to satisfy before it can
# be pointed at real data.
#
# A deck is a list of questions whose ORDER is the positional key every stored
# answer is filed under, so most of what can go wrong with one is structural: a
# card the player can't render, an option list with a duplicate in it, two decks
# claiming the same Verto. None of that fails loudly at import time — the rows
# go in and the Verto looks fine — which is why it is asserted here instead.
class VertoDecksTest < ActiveSupport::TestCase
  # A deck's `specs` is handed the importer so it can use its spec builders.
  # Nothing here reads a CSV, so an importer over an empty path is enough.
  def importer_for(key)
    VertoCsvImporter.new(csv_path: "/dev/null", deck: key)
  end

  test "every deck file on disk is fetchable by name" do
    assert_includes VertoDecks.available, "unyo_sport"

    VertoDecks.available.each do |key|
      assert_kind_of VertoDecks::Base, VertoDecks.fetch(key), "#{key} did not resolve to a deck"
    end
  end

  test "every concrete deck is listed, and only the shared parents are not" do
    # `abstract?` marks a class that exists only to be subclassed. Declared as a
    # bare `true` it is INHERITED, which silently removed both Happiness Project
    # flows from this list — and so from every test that iterates it, from
    # verto:preflight, and from the decks IMPORT_DECK offers. They still
    # imported, because fetch resolves any deck by name; nothing that asks what
    # decks exist could see them.
    on_disk = Dir[Rails.root.join("app/lib/verto_decks/*.rb")].map { |f| File.basename(f, ".rb") } - [ "base" ]

    assert_equal [ "walls_happiness" ], (on_disk - VertoDecks.available).sort,
      "only the shared parent class should be missing from the deck list"
    assert_includes VertoDecks.available, "walls_happiness_child"
    assert_includes VertoDecks.available, "walls_happiness_adult"
  end

  test "an unknown deck names the ones that exist rather than failing bare" do
    error = assert_raises(ArgumentError) { VertoDecks.fetch("no_such_deck") }

    assert_match(/no_such_deck/, error.message)
    assert_match(/unyo_sport/, error.message, "the error has to be actionable")
  end

  test "fetch passes a deck instance straight through" do
    deck = VertoDecks::UnyoSport.new

    assert_same deck, VertoDecks.fetch(deck)
  end

  # ── what every deck must produce ─────────────────────────────────────────
  test "every deck builds cards the app can actually render" do
    VertoDecks.available.each do |key|
      cards = VertoDecks.fetch(key).specs(importer_for(key)).map { |spec| spec[:card] }

      assert_operator cards.size, :>, 1, "#{key} built no questions"
      cards.each do |card|
        assert CardTypes.meta(card["type"]).present?,
          "#{key} builds a #{card['type'].inspect} card, which no card type covers"
        assert card["text"].present? || card["title"].present?,
          "#{key} builds a #{card['type']} card with nothing to read"
      end
    end
  end

  test "no deck offers the same option twice in one question" do
    # A duplicate option is invisible in the editor and halves that answer's
    # count when the results are aggregated by label.
    VertoDecks.available.each do |key|
      VertoDecks.fetch(key).specs(importer_for(key)).each do |spec|
        options = Array(spec[:card]["options"])
        next if options.empty?

        assert_equal options.uniq.size, options.size,
          "#{key} repeats an option in #{spec[:card]['text'].inspect}"
      end
    end
  end

  test "no two decks claim the same Verto" do
    # Sibling decks share an account on purpose (both Happiness Project flows
    # are Walls), but two decks pointing at one slug would overwrite each
    # other's Verto on every rebuild.
    slugs = VertoDecks.available.map { |key| VertoDecks.fetch(key).verto_slug }
    collisions = slugs.tally.select { |_slug, n| n > 1 }.keys - wll_shared_slug

    assert_empty collisions, "these Verto slugs are claimed by more than one deck: #{collisions.inspect}"
  end

  # The one deliberate exception: the WLL paper and digital decks ARE one Verto,
  # collected two ways. They differ only in collection_mode.
  def wll_shared_slug = [ VertoDecks::WllEducation.new.verto_slug ]

  test "the WLL halves are one Verto, told apart by collection mode" do
    paper   = VertoDecks.fetch("wll_education_paper")
    digital = VertoDecks.fetch("wll_education_digital")

    assert_equal paper.verto_slug, digital.verto_slug
    assert_equal paper.org_slug, digital.org_slug
    assert_equal "paper", paper.collection_mode
    assert_equal "digital", digital.collection_mode
    assert_equal paper.specs(importer_for("wll_education_paper")).map { |s| s[:card] },
                 digital.specs(importer_for("wll_education_digital")).map { |s| s[:card] },
                 "the two halves must reconstruct the SAME deck — answer keys are positional, " \
                 "so a card order that differs between them re-points every answer"
  end

  test "an ordinary deck stamps no collection mode at all" do
    # The column is NULL for a Verto collected one way, which is what keeps the
    # segment out of Ask Verto rather than publishing one meaningless cell.
    assert_nil VertoDecks.fetch("unyo_sport").collection_mode
    assert_empty VertoDecks.fetch("unyo_sport").non_answers
  end

  test "a deck with questions but no answers still builds a playable Verto" do
    deck  = VertoDecks.fetch("walls_happiness_child")
    specs = deck.specs(importer_for("walls_happiness_child"))

    assert(specs.all? { |spec| spec[:col].nil? && spec[:cols].nil? },
      "this deck has no export, so no spec may claim a column")
    assert(specs.all? { |spec| spec[:get].call(nil, nil).nil? },
      "and no spec may produce an answer")
  end
end
