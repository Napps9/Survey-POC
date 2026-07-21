# Builds tabular exports of a Verto's results from its (segment-scoped)
# responses. Returns plain arrays-of-arrays so the same rows can be streamed as
# CSV (ResultsExportsController) or written to a Google Sheet (GoogleSheetsWriter).
#
# Two tables are produced:
#   * #response_rows — one row per respondent, one column per question.
#   * #summary_rows  — aggregated counts/percentages, mirroring the results screen.
#
# `answers` is untrusted client JSON keyed by card index ("0", "1", …) with the
# shape { "type", "value", "other"? }; every accessor guards nil / wrong types.
class ResultsExport
  RESPONSE_HEADER = [ "Response ID", "Submitted at", "Source", "Language" ].freeze
  SUMMARY_HEADER  = [ "Card #", "Card type", "Question", "Answer option", "Count", "Percentage", "Total answers" ].freeze
  CHOICE_TYPES    = %w[multiple_choice yes_no select_one_grid select_many select_many_grid scenario].freeze

  # Spreadsheet formula-injection guard: Excel/Sheets treat a cell beginning
  # with one of these as a formula, so a respondent's free-text answer like
  # `=HYPERLINK(...)` would execute when the owner opens the export (and would
  # auto-evaluate in the Google Sheet). Such strings are prefixed with a quote.
  FORMULA_TRIGGERS = [ "=", "+", "-", "@", "\t", "\r" ].freeze

  def initialize(survey:, responses:, aggregated:)
    @survey     = survey
    @responses  = responses
    @aggregated = aggregated
  end

  # [header, *one row per response]. Question columns skip welcome cards.
  # Materialised form for the Google Sheets writer (needs the full array for its
  # batch API); the CSV download streams via each_row instead.
  def response_rows
    [].tap { |rows| each_response_row { |row| rows << row } }
  end

  # [header, *one row per answer option] built from the aggregated results.
  def summary_rows
    [].tap { |rows| each_summary_row { |row| rows << row } }
  end

  # Streaming entry point for the CSV download: yields one already-sanitized
  # row at a time so the controller never holds the whole table (or the whole
  # generated CSV string) in memory. For raw responses this pulls the DB rows
  # in batches via find_each rather than loading them all at once.
  def each_row(summary:, &block)
    summary ? each_summary_row(&block) : each_response_row(&block)
  end

  private

  def each_response_row
    yield csv_safe_row(RESPONSE_HEADER + question_cards.map { |card, _idx| question_text(card) })
    each_export_response do |response|
      answers = response.answers.is_a?(Hash) ? response.answers : {}
      yield csv_safe_row([
        response.id,
        response.created_at&.strftime("%Y-%m-%d %H:%M"),
        source_label(response),
        response.locale
      ] + question_cards.map { |card, idx| format_answer(card, answers[idx.to_s]) })
    end
  end

  def each_summary_row
    yield csv_safe_row(SUMMARY_HEADER)
    @aggregated.each_with_index do |result, idx|
      type = result[:type].to_s
      next unless CardTypes.question?(type)

      number   = idx + 1
      question = question_text(result[:card])
      total    = result[:total].to_i
      summary_option_rows(result, type).each do |label, count, pct|
        yield csv_safe_row([ number, type, question, label, count, pct, total ])
      end
    end
  end

  # Iterate the response set without loading it all at once. For an AR relation,
  # batch through find_each selecting only the columns the export reads; for an
  # in-memory array (e.g. tests), iterate directly.
  def each_export_response(&block)
    if @responses.respond_to?(:find_each)
      @responses.reorder(nil)
        .select(:id, :created_at, :locale, :survey_share_id, :answers)
        .find_each(batch_size: 500, &block)
    else
      @responses.each(&block)
    end
  end

  # [card, original_index] for every non-welcome card, so answers (keyed by the
  # original card index) still line up after welcome cards are dropped.
  def question_cards
    @question_cards ||= Array(@survey.cards).each_with_index.reject do |card, _idx|
      card.is_a?(Hash) && !CardTypes.question?(card["type"])
    end
  end

  def question_text(card)
    return "Untitled" unless card.is_a?(Hash)
    card["text"].presence || card["prompt"].presence || card["title"].presence || "Untitled"
  end

  # Maps a response back to a human label for which link it came through,
  # mirroring the results-screen segment labels.
  def source_label(response)
    return "Direct link" if response.survey_share_id.nil?
    share_labels[response.survey_share_id] || "Partner"
  end

  def share_labels
    @share_labels ||= @survey.survey_shares
      .includes(:partner_organisation, partnership_verto: :partnership)
      .each_with_object({}) do |share, h|
        partnership_name = share.partnership_verto&.partnership&.name
        h[share.id]   = partnership_name ? "#{share.display_name} · #{partnership_name}" : share.display_name
      end
  end

  # One CSV cell for a single answer, formatted per card type.
  def format_answer(card, answer)
    return "" unless answer.is_a?(Hash)

    value = answer["value"]
    other = answer["other"].presence

    text =
      case card["type"].to_s
      when "select_many", "select_many_grid"
        Array(value).map(&:to_s).reject(&:blank?).join("; ")
      when "range"
        range_label(card, value)
      when "tap_card"
        value.is_a?(Hash) ? value.map { |label, dir| "#{label}: #{dir}" }.join("; ") : ""
      else
        # multiple_choice, yes_no, select_one_grid, nps, rating, open_ended, …
        value.nil? ? "" : value.to_s
      end

    return text unless other
    text.present? ? "#{text}; Other: #{other}" : "Other: #{other}"
  end

  # A range answer's stored value is the zero-based step index; show its label.
  def range_label(card, value)
    return value.to_s unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
    i = value.to_i
    (Array(card["options"])[i].presence || "Step #{i + 1}").to_s
  end

  # [[label, count, percentage], …] for one aggregated result. Mirrors the
  # per-type rendering in app/views/surveys/results.html.erb.
  def summary_option_rows(result, type)
    counts = result[:counts] || {}
    case type
    when *CHOICE_TYPES
      # `counts` already includes an "Other" bucket when free-text was given.
      grand = counts.values.sum
      counts.sort_by { |_label, n| -n }.map { |label, n| [ label.to_s, n, pct(n, grand) ] }
    when "range"
      labels = Array(result.dig(:card, "options"))
      n      = [ labels.size, 2 ].max
      grand  = counts.values.sum
      Array.new(n) do |i|
        c = counts[i].to_i
        [ (labels[i].presence || "Step #{i + 1}").to_s, c, pct(c, grand) ]
      end + other_rows(result)
    when "rating"
      grand = counts.values.sum
      star_rows = (1..5).map { |star| [ "#{star} star#{star == 1 ? '' : 's'}", counts[star].to_i, pct(counts[star].to_i, grand) ] }
      star_rows + [ [ "Average (1–5)", result[:avg], nil ] ] + other_rows(result)
    when "nps"
      grand = counts.values.sum
      counts.keys.sort_by(&:to_i).map { |k| [ k.to_s, counts[k].to_i, pct(counts[k].to_i, grand) ] } + other_rows(result)
    when "prioritise"
      # counts[label] = sum of ranks; mean position = sum / total (lower = higher
      # priority). Export the ranked order with each option's average position.
      total = [ result[:total].to_i, 1 ].max
      counts.map { |label, sum| [ label.to_s, sum.to_f / total ] }
            .sort_by { |_l, mean| mean }
            .each_with_index.map { |(label, mean), i| [ "#{i + 1}. #{label}", "avg #{mean.round(2)}", nil ] }
    when "tap_card"
      counts.flat_map do |label, dirs|
        yes_c = dirs.is_a?(Hash) ? dirs["yes"].to_i    : 0
        no_c  = dirs.is_a?(Hash) ? dirs["no"].to_i     : 0
        uns_c = dirs.is_a?(Hash) ? dirs["unsure"].to_i : 0
        tot   = yes_c + no_c + uns_c
        [ [ "#{label} — Yes", yes_c, pct(yes_c, tot) ],
          [ "#{label} — Unsure", uns_c, pct(uns_c, tot) ],
          [ "#{label} — No", no_c, pct(no_c, tot) ] ]
      end + other_rows(result)
    when "open_ended"
      [ [ "(free-text responses)", Array(result[:texts]).size, nil ] ] + other_rows(result)
    else
      other_rows(result)
    end
  end

  # An "Other" free-text row for types that don't fold it into `counts`.
  def other_rows(result)
    others = Array(result[:other_texts])
    return [] if others.empty?
    [ [ "Other (free text)", others.size, nil ] ]
  end

  def pct(count, grand)
    return 0.0 unless grand.to_f.positive?
    ((count.to_f / grand) * 100).round(1)
  end

  def csv_safe_row(row)
    row.map { |cell| csv_safe(cell) }
  end

  # Neutralize a single cell against spreadsheet formula injection (see
  # FORMULA_TRIGGERS). Non-strings (counts, ids, percentages) pass through.
  def csv_safe(value)
    return value unless value.is_a?(String)
    value.start_with?(*FORMULA_TRIGGERS) ? "'#{value}" : value
  end
end
