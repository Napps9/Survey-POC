# The closed set of words that differ between the two English variants this
# product ships, and the transform that maps one to the other.
#
# Lives here rather than in lib/tasks/i18n.rake because it is product knowledge
# — which words the UI actually uses and how they are spelled on each side of
# the Atlantic — and because a rake file cannot be tested. `bin/rails i18n:en_us`
# generates config/locales/en-US.yml through this; LocaleEnUsTest checks both
# that the generated file is in sync and that this list hasn't fallen behind
# en.yml's copy.
#
# A word list rather than a regex, and that is the whole design. The near misses
# are the danger: "analysis" is identical in both variants, and so are "promise",
# "otherwise", "audience", "sequence", "confidence" and "preference" — every one
# of which appears in en.yml, and every one of which a blind /is([ae])/ rule
# would mangle.
module EnglishSpellings
  module_function

  BRITISH_TO_AMERICAN = {
    "organisation"  => "organization",  "organisations" => "organizations",
    "colour"        => "color",         "colours"       => "colors",
    "prioritise"    => "prioritize",    "optimise"      => "optimize",
    "optimising"    => "optimizing",    "customise"     => "customize",
    "summarise"     => "summarize",     "summarising"   => "summarizing",
    "tokenisation"  => "tokenization",  "recognised"    => "recognized",
    "authorised"    => "authorized",    "finalised"     => "finalized",
    "democratising" => "democratizing", "analysing"     => "analyzing",
    "analysed"      => "analyzed",      "unanalysed"    => "unanalyzed",
    "cancelled"     => "canceled",      "labelled"      => "labeled",
    "programme"     => "program"
  }.freeze

  PATTERN = /\b(#{BRITISH_TO_AMERICAN.keys.sort_by { |w| -w.length }.join('|')})\b/i

  # The shapes that USUALLY mark a British spelling. Used only by the test that
  # checks this list hasn't fallen behind the copy — a word matching one of
  # these and absent from both the map and IDENTICAL below is a new spelling
  # nobody has decided about yet.
  SUSPECT = /
    (?:is[ae]tion|isation|ising|ised|ise)$ | our(?:s|ed|ing)?$ | tres?$ |
    ogue$ | ences?$ | ll(?:ed|ing|er)$ | ysed$ | ysing$
  /xi.freeze

  # Words that MATCH the shapes above and are nonetheless spelled identically in
  # both variants. Every one of these is really in en.yml, which is why the
  # transform has to be a list and not a rule.
  IDENTICAL = %w[
    analysis audience audiences confidence democratise difference differences
    ellis experience experiences neurodivergence otherwise preference
    preferences promise recalled sequence sequences yours
  ].freeze

  # Case-preserving: shouty labels stay shouty ("PRIORITISE" → "PRIORITIZE"),
  # sentence case stays sentence case.
  def americanise(text)
    text.to_s.gsub(PATTERN) do |hit|
      replacement = BRITISH_TO_AMERICAN[hit.downcase]
      if hit == hit.upcase && hit.length > 1
        replacement.upcase
      elsif hit[0] == hit[0].upcase
        replacement.sub(/\A./, &:upcase)
      else
        replacement
      end
    end
  end

  # Words in `text` that look like they might be a variant spelling but are in
  # neither table — i.e. decisions nobody has made yet.
  def undecided(text)
    text.to_s.scan(/[A-Za-z]+/).map(&:downcase).uniq.select do |word|
      word.length > 4 && word.match?(SUSPECT) &&
        !BRITISH_TO_AMERICAN.key?(word) && !IDENTICAL.include?(word)
    end
  end
end
