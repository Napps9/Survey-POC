# Proves that an imported Verto still says what its export said.
#
# ── What is actually being checked ─────────────────────────────────────────
# For every question column, the arithmetic must close:
#
#     atoms in the source  ==  values stored on the Verto  +  values reported
#                                                             as not stored
#
# An "atom" is one answer inside a cell — a single-select cell holds one, a
# multi-select cell holds several, joined by "|||". Both sides of that identity
# are counted WITHOUT going through the deck's spec pipeline on the source
# side: the source is read as raw text (split, strip, de-duplicate), so a spec
# that quietly loses an answer cannot also hide it from the check.
#
# That single identity catches the failures that matter and are otherwise
# invisible:
#
#   * a column reading its neighbour's data — the totals stop matching the
#     column they are attributed to;
#   * a spec that drops a value without recording it — the left side exceeds
#     the right, and by exactly how many;
#   * an alignment error — a column that should hold 30,000 answers reports 0;
#   * a deck whose option list is missing a real option — the shortfall is
#     named, with the values behind it.
#
# It cannot prove the deck asks the right QUESTIONS; nothing can, short of the
# partner reading it. It proves that whatever the deck claims a column is, the
# answers under it are all present and correctly attributed.
class VertoReconciler
  # Per question column. `difference` is the number of source answers that are
  # neither stored nor accounted for — the only number that has to be zero.
  Line = Struct.new(:column, :question, :source, :stored, :reported, :inferred, :labels, keyword_init: true) do
    # source + inferred == stored + reported, rearranged. `inferred` is the one
    # place the Verto says MORE than the export did — a two-pile card sort
    # records "in neither pile" as unsure — and it is counted here rather than
    # waved through, so the identity still has to close.
    def difference = source + inferred - stored - reported
    def clean? = difference.zero?
  end

  Report = Struct.new(:lines, :rows, :responses, :rows_without_id, keyword_init: true) do
    def clean? = lines.all?(&:clean?)
    def problems = lines.reject(&:clean?)
  end

  def initialize(importer, survey)
    @importer = importer
    @survey   = survey
  end

  def call
    # The header first: a deck asks the importer which of several spellings a
    # column has, and a deck questioned before the file is opened answers nil
    # and silently drops that question out of the check.
    @importer.plan!
    @specs = @importer.build_specs
    specs  = @specs
    groups = group_specs(specs)
    source, rows = count_source(groups)
    stored = count_stored(specs)

    lines = groups.map do |group|
      Line.new(
        column:   group[:columns].join(" + "),
        question: group[:question],
        # Columns shared by several cards are counted ONCE. A card sort spreads
        # three pile columns across eight statement cards, so counting the
        # source per card would multiply the same answers eightfold and report
        # a shortfall that does not exist.
        source:   group[:columns].sum { |col| source[col].to_i },
        stored:   group[:indexes].sum { |idx| stored[idx].to_i },
        reported: group[:columns].sum { |col| reported_for(col) },
        inferred: group[:columns].sum { |col| @importer.inferred[col.to_s].values.sum },
        labels:   group[:columns].each_with_object(Hash.new(0)) { |col, out| @values[col].each { |v, n| out[v] += n } }
      )
    end

    Report.new(lines: lines, rows: rows, responses: @responses,
               rows_without_id: @importer.rows_without_id)
  end

  private

  def columns_for(spec) = spec[:col] ? [ spec[:col] ] : Array(spec[:cols]&.values).compact

  # Specs that read the SAME columns, grouped. Eight statement cards reading
  # one card sort's three piles are one group: between them they account for
  # those columns, and no one of them accounts for a third of them.
  def group_specs(specs)
    specs.each_with_index.filter_map { |spec, idx| [ spec, idx ] if columns_for(spec).any? }
         .group_by { |spec, _idx| columns_for(spec) }
         .map do |columns, pairs|
           { columns: columns, indexes: pairs.map(&:last), mode: mode_for(pairs.first.first),
             question: question_for(pairs.map(&:first)) }
         end
  end

  # Free text is never split. A respondent who typed "|||" wrote three
  # characters, not two answers — 216 cells in one export do exactly that — and
  # a cell holding the literal "[]" is a card sort's empty pile in one column
  # and somebody's actual answer in another.
  def mode_for(spec) = spec[:card]["type"].to_s == "open_ended" ? :text : :atoms

  def question_for(specs)
    return specs.first[:card]["text"].to_s if specs.size == 1

    "#{specs.size} cards from #{specs.first[:card]['text'].to_s.split(/[—?]/).first.to_s.strip}"
  end

  # The source, read as text. Deliberately NOT through the deck: the point of
  # the check is to have a second opinion, and a second opinion that reuses the
  # first one's judgement is not one.
  #
  # De-duplicated within a cell, because "Happy ||| Happy" is one answer given
  # twice by the export, not two answers given by the respondent — the importer
  # takes the same view, and a check that disagreed about it would report a
  # difference on every such cell.
  def count_source(groups)
    modes  = groups.flat_map { |g| g[:columns].map { |col| [ col, g[:mode] ] } }.to_h
    source = Hash.new(0)
    @values = Hash.new { |h, k| h[k] = Hash.new(0) }
    rows = 0

    @importer.each_row do |row|
      rows += 1
      modes.each do |col, mode|
        atoms = mode == :text ? text_atom(row[col]) : atoms_in(row[col])
        next if atoms.empty?

        source[col] += atoms.size
        atoms.each { |a| @values[col][a] += 1 }
      end

      # Replay the deck over the same row, purely to rebuild the import's own
      # not-stored ledger. The source counts above never touch it — they are
      # raw text — but the "reported" side of the identity is a record the
      # import produced, and a reconciler that could not see it would report
      # every deliberate omission as an unexplained loss.
      @importer.send(:response_attributes, @specs, row)
    end

    [ source, rows ]
  end

  def text_atom(cell)
    value = CGI.unescapeHTML(cell.to_s).strip
    value.empty? ? [] : [ value ]
  end

  # A card-sort pile arrives as a JSON array holding one "|||"-joined string,
  # and sometimes as the bare string. Both shapes are unwrapped here so a pile
  # is counted in atoms like every other column. An empty pile is the literal
  # "[]", never a blank cell.
  def atoms_in(cell)
    raw = CGI.unescapeHTML(cell.to_s).strip
    return [] if raw.empty? || raw == "[]"

    parsed = begin
      JSON.parse(raw) if raw.start_with?("[")
    rescue JSON::ParserError
      nil
    end
    Array(parsed || raw).flat_map { |chunk| chunk.to_s.split("|||") }
                        .map(&:strip).reject(&:empty?).uniq
  end

  # What the Verto actually holds, counted the same way: one per scalar answer,
  # one per entry in a list, one per option a card sort placed.
  def count_stored(specs)
    stored = Hash.new(0)

    # Only the responses THIS export produced. A Verto can hold two collection
    # channels (WLL is one programme collected on paper and digitally), and
    # reconciling one file against both halves would report the other half as a
    # surplus in every column.
    scope = @survey.responses.where("session_token LIKE ?", "#{@importer.token_prefix}%")
    scope = @survey.responses if scope.none?
    @responses = scope.count

    scope.find_each(batch_size: 1_000) do |response|
      specs.each_index do |idx|
        entry = response.answers[idx.to_s]
        next unless entry

        # An "Other" write-in is an answer even though the option it replaces is
        # nil — difficult_spec stores the typed text under its own key.
        stored[idx] += entry["value"].nil? && entry["other"].present? ? 1 : size_of(entry["value"])
      end
    end

    stored
  end

  def size_of(value)
    case value
    when Array then value.size
    when Hash  then value.count { |_option, pile| pile.to_s.present? }
    when nil   then 0
    else 1
    end
  end

  # Everything the import said it did not store, for this column.
  def reported_for(column)
    @importer.dropped[column.to_s].values.sum
  end
end
