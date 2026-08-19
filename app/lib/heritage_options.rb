# The five country-specific heritage categories a tailored Heritage card
# offers, with the cache and the sanitising that stand between Claude's answer
# and a respondent's screen.
#
# HeritageOptionsGenerator writes the list; this decides whether to believe it.
# Model output is never trusted verbatim (SurveyGenerator#normalize_framework!'s
# posture): labels are trimmed, bounded, de-duplicated, and checked against the
# two options the card already carries, and anything that doesn't survive as
# EXACTLY five clean entries returns nil so the caller falls back to the global
# nine-category taxonomy.
module HeritageOptions
  # A label longer than this is a sentence, not something to tap on a phone —
  # the same ceiling verto_rules.js applies to multiple_choice options.
  MAX_LABEL = 40

  # A country's list doesn't change between Tuesday and Wednesday, and the same
  # org tends to build several Vertos for the same audience. Cached in Solid
  # Cache (persistent, unlike the old per-process store), so a country is
  # generated once and every later insert is free and identical — which also
  # means two Vertos for the same country get the SAME options, and their
  # results line up.
  CACHE_TTL = 90.days

  # Bumped when the prompt or the sanitising changes, so stale lists from an
  # older contract don't outlive it.
  CACHE_VERSION = "v1".freeze

  # A catch-all the card already provides, slipped in as one of the five —
  # rendering it twice would split that answer's count between two rows.
  # English-only and anchored on purpose: the exact-match check against the
  # locale's own tail is what holds in French or Arabic, and a looser pattern
  # would eat real categories ("Mixed race" is Brazil's largest, not a
  # catch-all).
  CATCH_ALL = /\A(another|any other|other|none of these|prefer not\b.*)\z/i

  class << self
    # Returns an array of HeritageOptionsGenerator::WANTED labels for `country`
    # (ISO 3166-1 alpha-2) written in `locale`, or nil if we couldn't get a
    # usable list. nil is a MISSING verdict, never "this country has none" —
    # callers fall back to the global taxonomy.
    def for(country:, locale: SupportedLocales::DEFAULT)
      code = country.to_s.strip.upcase
      return nil unless WorldRegions.valid?(code)

      cached = Rails.cache.read(cache_key(code, locale))
      return cached if cached.is_a?(Array) && cached.size == HeritageOptionsGenerator::WANTED

      raw   = generator.call(country: code, locale: locale)
      clean = sanitize(raw, locale: locale)
      # Only a good list is cached. Caching nil would pin a country to the
      # global taxonomy for 90 days because of one bad afternoon at the API.
      Rails.cache.write(cache_key(code, locale), clean, expires_in: CACHE_TTL) if clean
      clean
    end

    # Exposed for tests and for the sanitising above: everything that has to be
    # true of a list before it reaches a respondent. Returns the cleaned array
    # or nil — never a short list, because a Heritage card with three options
    # is worse than the global one it replaced.
    def sanitize(list, locale: SupportedLocales::DEFAULT)
      return nil unless list.is_a?(Array)

      # Labels the card already carries as its tail. A model that returns
      # "Prefer not to say" as one of its five would otherwise render it twice,
      # and the duplicate would split that answer's count in the results.
      taken = DemographicQuestions.heritage_tail_options(locale: locale).map { |o| o.to_s.downcase }

      seen = {}
      list.each do |raw|
        label = clean_label(raw)
        next if label.blank?

        key = label.downcase
        next if taken.include?(key) || CATCH_ALL.match?(key) || seen.key?(key)

        seen[key] = label
      end

      clean = seen.values
      clean if clean.size == HeritageOptionsGenerator::WANTED
    end

    private

    def clean_label(raw)
      raw.to_s
         .gsub(/[[:cntrl:]]/, " ") # a newline in an option label breaks the row
         .tr("|", " ")             # a pipe has packed a demographic column before; keep them out of answers
         .squeeze(" ")
         .strip
         .first(MAX_LABEL)
         .to_s
         .strip
    end

    def cache_key(code, locale)
      "heritage-options:#{CACHE_VERSION}:#{code}:#{locale}"
    end

    def generator
      HeritageOptionsGenerator.new
    end
  end
end
