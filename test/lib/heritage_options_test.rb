require "test_helper"

# The seam between what Claude returned and what a respondent is asked to
# describe themselves with. Nothing here trusts the model: the contract is
# EXACTLY five clean labels or nil, because a Heritage card offering three
# categories is worse than the global nine it replaced.
class HeritageOptionsTest < ActiveSupport::TestCase
  FIVE = [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ].freeze

  # A generator that never touches the network, counting calls so the cache
  # tests can prove the second insert was free.
  class FakeGenerator
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls  = 0
    end

    def call(country:, locale: nil)
      @calls += 1
      @result
    end
  end

  def with_generator(result)
    fake = FakeGenerator.new(result)
    HeritageOptionsGenerator.define_singleton_method(:new) { |*| fake }
    yield fake
  ensure
    HeritageOptionsGenerator.singleton_class.remove_method(:new)
  end

  # The suite runs on :null_store, so a cache assertion needs a real store.
  def with_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  # ── Sanitising ────────────────────────────────────────────────────────────

  test "a clean list of five passes through" do
    assert_equal FIVE, HeritageOptions.sanitize(FIVE)
  end

  test "labels are trimmed and capped at the phone-readable ceiling" do
    long = "A" * 80
    out  = HeritageOptions.sanitize([ "  White British  ", "Indian", "Pakistani", "Chinese", long ])

    assert_equal "White British", out.first, "surrounding whitespace is not part of the answer"
    assert_equal HeritageOptions::MAX_LABEL, out.last.length
  end

  test "newlines, control characters and pipes never reach an option label" do
    out = HeritageOptions.sanitize([ "White\nBritish", "In\tdian", "Paki|stani", "Black Caribbean", "Chinese" ])

    assert_equal "White British", out[0]
    assert_equal "In dian", out[1]
    # A pipe is how the neurodiversity column packs multi-select answers; a
    # label carrying one is dropped there, so it never gets to be one here.
    assert_equal "Paki stani", out[2]
  end

  test "a list that duplicates itself is short, and short is nil" do
    dupes = [ "Indian", "indian", "INDIAN", "Chinese", "Pakistani" ]
    assert_nil HeritageOptions.sanitize(dupes),
               "three of these collapse to one, leaving three — fewer than five is a failure, not a short card"
  end

  test "the card's own tail options are dropped rather than rendered twice" do
    # "Another heritage" and "Prefer not to say" already sit below the five.
    with_tail = FIVE.first(4) + [ "Prefer not to say" ]
    assert_nil HeritageOptions.sanitize(with_tail)
  end

  test "the tail is recognised in the Verto's own language, not just English" do
    fr_tail = DemographicQuestions.heritage_tail_options(locale: "fr").last
    assert_nil HeritageOptions.sanitize(FIVE.first(4) + [ fr_tail ], locale: "fr"),
               "a French Verto's tail pair is French; matching only English would let it through"
  end

  test "catch-all categories are dropped — the free-text Other box is the catch-all" do
    [ "Other", "Another", "Any other", "None of these", "Prefer not to answer" ].each do |catch_all|
      assert_nil HeritageOptions.sanitize(FIVE.first(4) + [ catch_all ]),
                 "#{catch_all.inspect} duplicates what the card already offers"
    end
  end

  test "a real category that merely reads like a catch-all survives" do
    # Brazil's largest single category is mixed heritage ("Pardo"). A looser
    # catch-all pattern would delete it, which is the failure this guards.
    out = HeritageOptions.sanitize([ "Pardo", "Branco", "Preto", "Amarelo", "Mixed race" ])
    assert_includes out, "Mixed race"
    assert_includes out, "Pardo"
  end

  test "anything that is not exactly five clean labels is nil" do
    assert_nil HeritageOptions.sanitize(nil)
    assert_nil HeritageOptions.sanitize([]),                    "the no-accepted-set answer"
    assert_nil HeritageOptions.sanitize(FIVE.first(4)),         "too few"
    assert_nil HeritageOptions.sanitize(FIVE + [ "Sixth" ]),    "too many"
    assert_nil HeritageOptions.sanitize([ "", "  ", nil, "\n", "x" ]), "blanks are not labels"
  end

  # ── Lookup, caching and the fallback ──────────────────────────────────────

  test "an unknown country never reaches the generator" do
    with_generator(FIVE) do |fake|
      assert_nil HeritageOptions.for(country: "ZZ")
      assert_equal 0, fake.calls
    end
  end

  test "a country is generated once and every later Verto reuses it" do
    with_cache do
      with_generator(FIVE) do |fake|
        assert_equal FIVE, HeritageOptions.for(country: "GB")
        assert_equal FIVE, HeritageOptions.for(country: "GB")
        assert_equal 1, fake.calls, "the second insert must be free"
        # Same country, same list — which is what keeps two Vertos for the
        # same audience comparable.
        assert_equal HeritageOptions.for(country: "GB"), FIVE
      end
    end
  end

  test "each language is cached on its own" do
    with_cache do
      with_generator(FIVE) do |fake|
        HeritageOptions.for(country: "GB", locale: "en")
        HeritageOptions.for(country: "GB", locale: "fr")
        assert_equal 2, fake.calls, "a French card's labels are French — not the English cache entry"
      end
    end
  end

  test "a failure is never cached" do
    with_cache do
      with_generator(nil) do |fake|
        assert_nil HeritageOptions.for(country: "GB")
        assert_nil HeritageOptions.for(country: "GB")
        assert_equal 2, fake.calls,
                     "caching nil would pin a country to the global list for 90 days over one bad afternoon"
      end
    end
  end

  test "an unusable list degrades to nil so the caller falls back to the global nine" do
    with_generator([ "Only", "Three", "Here" ]) do
      assert_nil HeritageOptions.for(country: "GB")
    end
  end
end
