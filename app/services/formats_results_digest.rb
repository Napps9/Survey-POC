# Renders aggregated survey results as a plain-text digest for Claude prompts —
# shared by the short insights summary (ResultsSummariser) and the full AI
# report (ResultsReportGenerator), so both describe the underlying data
# identically.
module FormatsResultsDigest
  private

  def results_digest(survey, aggregated, total)
    lines = []
    lines << "Survey: \"#{survey.title}\""
    lines << "Theme: #{survey.theme}"
    lines << "Key insight goal: #{survey.key_insight}"
    lines << "Total responses: #{total}"
    lines << ""
    lines << "Per-question results:"
    lines << ""

    aggregated.each_with_index do |result, idx|
      type = result[:type]
      card = result[:card]
      next if type == "welcome_card"

      lines << "Q#{idx + 1} [#{type}]: #{card["text"]}"

      case type
      when "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid"
        counts = result[:counts]
        grand  = counts.values.sum.to_f
        grand  = 1.0 if grand.zero?
        counts.sort_by { |_, v| -v }.each do |label, count|
          pct = ((count / grand) * 100).round
          lines << "  #{label}: #{count} (#{pct}%)"
        end

      when "tap_card"
        result[:counts].each do |label, dirs|
          yes_c = dirs["yes"].to_i
          no_c  = dirs["no"].to_i
          uns_c = dirs["unsure"].to_i
          tot   = (yes_c + no_c + uns_c).to_f
          tot   = 1.0 if tot.zero?
          lines << "  \"#{label}\" → Yes #{yes_c} (#{((yes_c / tot) * 100).round}%), Unsure #{uns_c} (#{((uns_c / tot) * 100).round}%), No #{no_c} (#{((no_c / tot) * 100).round}%)"
        end

      when "range"
        labels = Array(card["options"])
        grand  = result[:counts].values.sum.to_f
        grand  = 1.0 if grand.zero?
        result[:counts].sort.each do |step, count|
          label = labels[step] || "Step #{step + 1}"
          pct   = ((count / grand) * 100).round
          lines << "  #{label}: #{count} (#{pct}%)"
        end

      when "rating"
        lines << "  Average: #{result[:avg]} / 5 (#{result[:total]} responses)"
        result[:counts].sort.each do |star, count|
          lines << "  #{star} star#{"s" if star != 1}: #{count}"
        end

      when "open_ended"
        sample = result[:texts].first(5)
        lines << "  Sample responses (#{result[:total]} total):"
        sample.each { |t| lines << "    - \"#{t.truncate(120)}\"" }
      end

      lines << ""
    end

    lines.join("\n")
  end
end
