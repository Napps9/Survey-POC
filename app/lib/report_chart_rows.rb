# Turns one aggregated card into the rows a report chart draws.
#
# The report used to be AI prose only — no numbers a reader could check the
# narrative against. This supplies the "summary statistics and charts" half.
#
# The per-type shapes mirror ResultsExport#summary_option_rows deliberately, so
# the PDF and the summary CSV can never disagree about a question's numbers.
# They are genuinely different per type: choice cards key counts by label, range
# by scale index, rating by star, nps by score, and tap_card nests a
# yes/unsure/no hash per statement.
#
# prioritise is deliberately absent. Its `counts` hold a SUM OF RANKS, not a
# tally — drawing those as bars would read as "how many people chose this" and
# be exactly backwards (there, lower is better). It stays in the CSV, where it
# is labelled as an average position.
module ReportChartRows
  module_function

  Row = Struct.new(:label, :count, :pct, keyword_init: true)

  # Beyond this a bar list stops being readable on a page and starts being a
  # table. The long tail is in the CSV export, which the note points at.
  MAX_ROWS = 12

  LABELLED_COUNTS = %w[multiple_choice yes_no select_one_grid select_many
                       select_many_grid scenario].freeze

  # True when this card's answers are countable categories worth drawing. A
  # single-category result is a number, not a chart — a one-bar bar chart is a
  # stat tile wearing a costume.
  def chartable?(result)
    rows_for(result).size >= 2
  end

  def rows_for(result)
    rows = raw_rows(result)
    return [] if rows.empty?

    grand = rows.sum { |row| row[1] }
    return [] unless grand.positive?

    rows.first(MAX_ROWS).map do |label, count, denominator|
      # A row can name its own denominator. tap_card needs it: each statement is
      # its own yes/unsure/no question, so a share against the whole card's
      # answers would read as "9% said yes" when 43% of that statement did.
      base = (denominator || grand).to_f
      Row.new(label: label, count: count, pct: base.positive? ? (count * 100.0 / base).round : 0)
    end
  end

  # Whether anything was left out, so the note only appears when it's true.
  # tap_card caps by statement inside raw_rows, so its own rows never exceed
  # MAX_ROWS — the drop has to be detected against the source counts.
  def truncated?(result)
    counts = result[:counts]
    return false unless counts.is_a?(Hash)
    return counts.size > MAX_ROWS / 3 if result[:type].to_s == "tap_card"

    raw_rows(result).size > MAX_ROWS
  end

  # [[label, integer_count, denominator_or_nil], ...] — ordered for display,
  # biggest first where order is arbitrary, and in scale order where it isn't (a
  # range or NPS drawn biggest-first would scramble the scale it measures).
  def raw_rows(result)
    counts = result[:counts]
    return [] unless counts.is_a?(Hash) && counts.any?

    case result[:type].to_s
    when *LABELLED_COUNTS
      counts.filter_map { |label, n| [ label.to_s, n.to_i ] if n.is_a?(Numeric) }
            .sort_by { |_label, n| -n }
    when "range"
      labels = Array(result.dig(:card, "options"))
      [ labels.size, 2 ].max.times.map do |i|
        [ (labels[i].presence || "Step #{i + 1}").to_s, counts[i].to_i ]
      end
    when "rating"
      (1..5).map { |star| [ "#{star} star#{star == 1 ? '' : 's'}", counts[star].to_i ] }
    when "nps"
      counts.keys.sort_by(&:to_i).map { |k| [ k.to_s, counts[k].to_i ] }
    when "tap_card"
      # Whole statements only — MAX_ROWS/3 of them — so truncation never cuts a
      # statement off mid-way and leaves a stray "— No" with no question.
      counts.first(MAX_ROWS / 3).flat_map do |label, dirs|
        next [] unless dirs.is_a?(Hash)

        yes, unsure, no = dirs["yes"].to_i, dirs["unsure"].to_i, dirs["no"].to_i
        statement_total = yes + unsure + no
        [ [ "#{label} — Yes", yes, statement_total ],
          [ "#{label} — Unsure", unsure, statement_total ],
          [ "#{label} — No", no, statement_total ] ]
      end
    else
      []
    end
  end

  # Whole-Verto figures for the stat strip. Completion is expressed against
  # responders rather than every session, matching the dashboard: someone who
  # opened the link and never answered isn't a denominator.
  def summary_stats(survey)
    responders = survey.responses.where(answered: true).count
    completed  = survey.responses.where(answered: true, status: "completed").count
    questions  = Array(survey.cards).count { |c| c.is_a?(Hash) && CardTypes.question?(c["type"]) }

    {
      responders: responders,
      completed:  completed,
      completion: responders.positive? ? (completed * 100.0 / responders).round : 0,
      questions:  questions
    }
  end
end
