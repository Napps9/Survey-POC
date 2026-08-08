# Puts a Playverto response export's header row back over the right columns.
#
# ── The bug this exists for ────────────────────────────────────────────────
# Some exports carry one more DATA column than their header row names. In the
# WLL Transforming Education exports the data has an unnamed column at index 13
# — the value for "Accepted Polling and Survey", which the header omits — so
# from that point on every header names the PREVIOUS column's data:
#
#   header[13] "Completion percentage"  →  data[13] = True      (a consent flag)
#   header[14] "Position"               →  data[14] = 21.43     (the completion %)
#   header[15] "Language"               →  data[15] = "3/14"    (the position)
#   header[24] "I enjoy school…"        →  data[24] = "Calm"    (a different question)
#
# VertoCsvImporter looks every column up BY NAME (`row["Language"]`,
# `spec[:get].call(row, header)`), so on a file like this it does not fail — it
# succeeds, and silently attributes every answer to the wrong question. The
# import would report a clean run and the corpus would be confidently wrong.
# That is the worst possible failure mode for a product whose whole promise is
# that a cited figure came from the question it says it did.
#
# ── Why the shape of the data, and not the names ───────────────────────────
# The obvious detector — "which canonical preamble column is the header
# missing?" — does not work. ALL THREE exports checked omit "Accepted Polling
# and Survey" from their header, including the one whose data is perfectly
# aligned. The header names alone cannot tell the two cases apart.
#
# What can is the DATA. A handful of preamble columns have unmistakable value
# shapes — a language is two letters, a position is "3/14", a completion
# percentage is a number, a viewing path is a JSON array — so the offset is
# found by trying each candidate and scoring how many of those hold. On the
# real files the correct answer scores in the hundreds and every other
# candidate scores zero, which is the margin that makes this safe to automate.
#
# ── The shift does not have to reach the questions ─────────────────────────
# The two WLL exports are shifted the same way in the preamble and DIFFERENTLY
# from there on. The paper file stays +1 to the last column. The digital file
# also has a header with no data column of its own ("Points"), which cancels
# the insertion out, so its questions are aligned 1:1 — and correcting it as if
# it were the paper file would misattribute every single answer.
#
# So the preamble and the questions are measured separately, against different
# evidence: the preamble by its value shapes, the questions by the source-type
# suffix their headers carry ("(pickMany)" and "(priority)" columns hold
# "|||"-joined lists, "(age)" holds a number). A question shift can only be at
# or below the preamble's — a header cannot gain a column it never had.
#
# If no candidate wins convincingly in either region, this raises. A misaligned
# import is worse than no import, so an ambiguous file is refused, not guessed
# at.
module VertoExportLayout
  module_function

  # Offsets worth trying. Wider than the one case seen so far, because the next
  # export may drop two preamble columns rather than one.
  CANDIDATE_SHIFTS = (0..3).freeze

  # Rows sampled to score a candidate. Enough that a stretch of abandoned rows
  # can't sway it, small enough to stay cheap on a 50,000-row export.
  SAMPLE_SIZE = 200

  # A row has to carry at least this many values to be worth scoring. Exports
  # open with a run of rows where someone loaded the first card and left, and
  # those are evidence of nothing.
  MIN_ROW_FILL = 12

  # The column the preamble's unmistakable block starts at. Placeholders are
  # inserted immediately before it, because everything earlier — the ids, the
  # timestamps, the consent booleans — is aligned in every export seen.
  ANCHOR = "Completion percentage".freeze

  # Preamble columns whose values are recognisable on sight, and the test for
  # each.
  PROBES = {
    "Completion percentage" => ->(v) { v.to_s.strip.match?(/\A\d+(\.\d+)?\z/) },
    "Position"              => ->(v) { v.to_s.strip.match?(%r{\A\d+/\d+\z}) },
    "Language"              => ->(v) { v.to_s.strip.match?(/\A[a-z]{2}\z/) },
    "Viewing path"          => ->(v) { v.to_s.strip.start_with?("[") }
  }.freeze

  # A question column announces its source answer type in its own name. Those
  # types have value shapes as recognisable as the preamble's, which is what
  # lets the question region be measured independently of it.
  QUESTION_PROBES = [
    [ /\((?:pickMany|priority|matrix)\)/i, ->(v) { v.to_s.include?("|||") } ],
    [ /\(decision - /i,                    ->(v) { v.to_s.include?("|||") || v.to_s.strip.start_with?("[") } ],
    [ /\(age\)/i,                          ->(v) { v.to_s.strip.match?(/\A\d{1,2}\z/) || v.to_s.strip.match?(/\A\d{4}-\d{2}/) } ]
  ].freeze

  # Where the questions begin: the first header carrying a source-type suffix.
  TYPED_HEADER = /\([A-Za-z][^()]*\)\s*\z/

  # A shift is only accepted when it clears this many probe hits AND beats
  # every rival by this margin. On the real files the preamble winner scores
  # 700+ against 0; the question winner wins by 2.5–4×.
  MIN_CONFIDENCE = 12
  MIN_MARGIN = 1.25

  class AmbiguousLayout < StandardError; end

  # What the header should have been. `headers` is the corrected list — long
  # enough to cover the data, with placeholders where the export named nothing
  # and any orphaned names moved to the end.
  Plan = Struct.new(:headers, :shift, :tail_shift, :confidence, keyword_init: true) do
    def realigned? = shift.positive?
    def piecewise? = shift != tail_shift
  end

  Result = Struct.new(:rows, :shift, :tail_shift, :confidence, keyword_init: true) do
    def realigned? = shift.positive?

    # True when the preamble is shifted and the questions are not — the case
    # where correcting the whole row would be as wrong as correcting none of it.
    def piecewise? = shift != tail_shift
  end

  # Takes a CSV::Table (read with headers: true) and returns a Result whose rows
  # can be read by header name correctly, whether or not the file was shifted.
  #
  # Aligned files are returned untouched — no copying, no risk of changing
  # behaviour for the exports that were always fine.
  def realign(table)
    plan = plan_for(table.headers.map(&:to_s), sample_rows(table.each.map(&:fields)))
    rows = plan.realigned? ? table.map { |row| CSV::Row.new(plan.headers, row.fields) } : table.each.to_a
    # `each.to_a`, not `to_a`: CSV::Table#to_a yields the header plus raw field
    # ARRAYS, which have no `row["Language"]` — every caller downstream reads by
    # name, so rows must stay CSV::Row.
    Result.new(rows: rows, shift: plan.shift, tail_shift: plan.tail_shift, confidence: plan.confidence)
  end

  # The decision on its own, without the rows.
  #
  # An export large enough to matter (127 MB, 126,895 rows) cannot be held in
  # memory to be corrected — but the DECISION only ever needed the header and a
  # bounded sample. So the caller reads a little, asks for a plan, and then
  # streams the whole file against `plan.headers`, which is the corrected header
  # list every `row["Some Question (range)"]` lookup resolves through.
  #
  # `sample` is raw field arrays, not CSV::Row, precisely so a streaming caller
  # does not have to build rows before it knows what the header is.
  def plan_for(headers, sample)
    scores = CANDIDATE_SHIFTS.to_h { |shift| [ shift, score(headers, sample, shift) ] }
    shift  = decide!(scores, "preamble")

    return Plan.new(headers: headers, shift: 0, tail_shift: 0, confidence: scores[shift]) if shift.zero?

    tail_scores = (0..shift).to_h { |s| [ s, question_score(headers, sample, s) ] }
    tail_shift  = decide!(tail_scores, "question")

    Plan.new(headers: padded_headers(headers, shift, tail_shift),
             shift: shift, tail_shift: tail_shift, confidence: scores[shift])
  end

  # The rows worth scoring: the first SAMPLE_SIZE with real content, falling
  # back to the first SAMPLE_SIZE outright when nothing clears the bar (a tiny
  # fixture, an export of abandonments) so the decision is still made on
  # evidence rather than on an empty set.
  def sample_rows(rows)
    filled = rows.lazy.select { |fields| fields.count { |v| v.to_s.strip != "" } >= MIN_ROW_FILL }
                 .first(SAMPLE_SIZE)
    filled.presence || rows.first(SAMPLE_SIZE)
  end

  # How many probe values land where `shift` says they should.
  def score(headers, sample, shift)
    PROBES.sum do |name, test|
      index = headers.index(name)
      next 0 if index.nil?

      hits(sample, index + shift, test)
    end
  end

  # The same measurement over every question column the header names, which is
  # what says whether the preamble's shift carries on into the answers.
  def question_score(headers, sample, shift)
    QUESTION_PROBES.sum do |pattern, test|
      headers.each_index.select { |i| headers[i].match?(pattern) }
             .sum { |i| hits(sample, i + shift, test) }
    end
  end

  def hits(sample, target, test)
    sample.count { |fields| target < fields.size && test.call(fields[target]) }
  end

  # Picks the winning shift, or refuses. A near-tie means the evidence doesn't
  # actually distinguish the layouts, which is exactly the case where being
  # wrong leaves no visible symptom.
  def decide!(scores, region)
    best, top = scores.max_by { |_shift, count| count }
    rival = scores.except(best).values.max.to_i

    if top < MIN_CONFIDENCE || top < rival * MIN_MARGIN
      raise AmbiguousLayout,
            "Could not work out this export's #{region} column layout (scores: #{scores.inspect}). " \
            "Refusing to import rather than risk attributing answers to the wrong questions."
    end
    best
  end

  # Rebuild each row against a header list padded with `shift` placeholders, so
  # every existing `row["Some Question (range)"]` lookup downstream resolves to
  # the column it was always meant to.
  #
  # Padding the headers rather than dropping data columns keeps the fix in one
  # place: nothing else in the importer has to know this happened.
  def shifted_rows(table, headers, shift, tail_shift)
    padded = padded_headers(headers, shift, tail_shift)
    table.map { |row| CSV::Row.new(padded, row.fields) }
  end

  # Reads only as much of the file as the decision needs, then hands back the
  # corrected header. `open` yields a fresh IO positioned at the start.
  SCAN_LIMIT = 20_000

  def plan_from(&open)
    headers = nil
    sample  = []

    open.call.then do |io|
      begin
        CSV.new(io).each do |fields|
          if headers.nil?
            # A BOM survives as part of the first header name and would make
            # row["Viewing ID"] miss by one invisible character.
            headers = fields.map(&:to_s)
            headers[0] = headers[0].delete_prefix("\uFEFF")
            next
          end
          sample << fields
          break if sample.size >= SCAN_LIMIT
        end
      ensure
        io.close
      end
    end

    raise AmbiguousLayout, "This export has no header row." if headers.nil?

    plan_for(headers, sample_rows(sample))
  end

  def padded_headers(headers, shift, tail_shift)
    at           = headers.index(ANCHOR) || 0
    placeholders = Array.new(shift) { |i| "__unnamed_#{i + 1}" }
    drop         = shift - tail_shift
    return headers.dup.insert(at, *placeholders) if drop.zero?

    # `drop` of the header's own names have no data column. They can only be
    # preamble names — the question region has just been measured as aligned —
    # so they are taken from the END of the preamble, the stretch no probe
    # covers. They are kept, at the end, so `row["Points"]` still answers
    # (with nothing) instead of raising.
    boundary = questions_start(headers, at)
    keep_to  = boundary - drop
    if keep_to <= at
      raise AmbiguousLayout,
            "This export's preamble is too short to account for #{drop} unnamed column(s). " \
            "Refusing to import rather than risk attributing answers to the wrong questions."
    end

    headers[0...at] + placeholders + headers[at...keep_to] + headers[boundary..] + headers[keep_to...boundary]
  end

  def questions_start(headers, from)
    headers.each_index.find { |i| i > from && headers[i].match?(TYPED_HEADER) } || headers.size
  end
end
