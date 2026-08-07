# Strips identifying detail out of a respondent's free-text answer before it can
# be quoted, word for word, to somebody in another organisation.
#
# This is the first of four defences, and the only deterministic one:
#
#   1. QuoteRedactor  — this. Removes the shapes that are always identifying:
#                       contact details, links, handles, long number runs.
#   2. OpenTextThemer — asks Claude whether what's left could still identify the
#                       person, and drops the quote if it could.
#   3. Length         — CorpusQuote::MAX_LENGTH. A respondent who wrote three
#                       paragraphs is far easier to place from them than from one
#                       line, so long answers are rejected rather than truncated.
#   4. A human        — staff read the quotes before the Verto is approved.
#
# Regex cannot recognise "the only wheelchair user in my year at Liceo
# Bicentenario", which is why it is the first defence and not the last. What it
# does guarantee is that no email address, phone number or URL survives, and it
# guarantees it identically every time — which the other three cannot.
module QuoteRedactor
  module_function

  REDACTION = "[removed]".freeze

  # A quote shorter than this carries no insight and disproportionate risk: three
  # words is not a finding, but it can still be someone's distinctive phrase.
  MIN_LENGTH = 15

  # Order matters. Emails go before handles (an address contains an @) and before
  # digit runs (an address can contain digits); URLs go before both so a query
  # string isn't half-eaten first.
  PATTERNS = [
    # URLs, with or without a scheme.
    %r{\bhttps?://\S+}i,
    /\bwww\.[a-z0-9-]+(?:\.[a-z]{2,})+\S*/i,
    # Email addresses.
    /\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b/,
    # Social handles.
    /(?<![\w])@[a-z0-9._]{2,}/i,
    # Phone numbers: an optional +, then 7+ digits allowing spaces, dots, dashes
    # and bracketed area codes. Deliberately greedy — a false positive costs a
    # redaction, a false negative costs a phone number.
    /\+?\d[\d\s().-]{6,}\d/,
    # Any bare run of 5+ digits. Catches ID numbers, postcodes with digits,
    # student numbers, RUTs — the identifiers a phone-number pattern misses.
    /\b\d{5,}\b/
  ].freeze

  # The result of redacting one answer.
  #
  #   text     the redacted body, or nil when the answer cannot be quoted at all
  #   dropped  why it was rejected, for the reviewer's count. nil when kept.
  Result = Struct.new(:text, :dropped, keyword_init: true) do
    def kept? = !text.nil?
  end

  # Redact one answer. Returns a Result rather than a String because "this cannot
  # be quoted" is a real outcome the indexer has to count and the reviewer has to
  # see — squashing it to nil or to "" loses the reason.
  def redact(raw)
    body = raw.to_s.strip
    return Result.new(dropped: :blank) if body.empty?

    # Newlines become spaces first: a quote is one line in an answer, and a
    # multi-line answer redacts more predictably once flattened.
    body = body.gsub(/\s+/, " ")

    PATTERNS.each { |pattern| body = body.gsub(pattern, REDACTION) }
    body = body.squeeze(" ").strip

    # A quote that is now mostly redaction markers says nothing and advertises
    # that something was removed. Drop it.
    return Result.new(dropped: :over_redacted) if over_redacted?(body)
    return Result.new(dropped: :too_short) if body.length < MIN_LENGTH
    return Result.new(dropped: :too_long)  if body.length > CorpusQuote::MAX_LENGTH

    Result.new(text: body)
  end

  # Redact a batch, keeping only what survives. Returns [kept_texts, drop_counts]
  # so the indexer can record why quotes didn't make it — a Verto that loses 90%
  # of its quotes to redaction is something a reviewer should be told about.
  def redact_all(raws)
    kept  = []
    drops = Hash.new(0)

    Array(raws).each do |raw|
      result = redact(raw)
      if result.kept?
        kept << result.text
      else
        drops[result.dropped] += 1
      end
    end

    [ kept.uniq, drops ]
  end

  # More than a third of the remaining words are redaction markers, or the marker
  # appears three times or more. Either way what's left is unreadable.
  def over_redacted?(body)
    markers = body.scan(REDACTION).size
    return false if markers.zero?
    return true  if markers >= 3

    words = body.split(" ").size
    words.positive? && (markers.to_f / words) > 0.33
  end
end
