# Shared report plumbing for the PDF download (ResultsReportsController) and the
# Google Doc export (GoogleDriveExportsController): generate + cache the report
# markdown, and render it as a body fragment (for the on-page preview) or a full
# styled HTML document (for the PDF and the Google Doc).
module GeneratesResultsReport
  extend ActiveSupport::Concern
  include AggregatesSurveyResults

  private

  # The report markdown for `survey`, generating + caching it when missing or
  # stale (cache is keyed to the completed-response count, like the summary).
  def results_report_markdown(survey)
    responses = survey.responses.where(status: "completed")
    total     = responses.count

    if survey.results_report.present? && survey.results_report_response_count == total
      return survey.results_report
    end

    aggregated = aggregate_results(Array(survey.cards), responses.order(created_at: :desc))
    markdown   = ResultsReportGenerator.call(survey: survey, aggregated: aggregated, total: total)
    if markdown.present?
      survey.update_columns(results_report: markdown, results_report_response_count: total)
    end
    markdown
  end

  # Streams the report markdown chunk-by-chunk (yielding to the block) while
  # generating, caching the full text on completion. Replays the cache in one
  # write when it's still fresh. Mirrors the insights-summary streaming.
  def stream_results_report(survey)
    responses = survey.responses.where(status: "completed")
    total     = responses.count

    if survey.results_report.present? && survey.results_report_response_count == total
      yield survey.results_report
      return
    end

    aggregated = aggregate_results(Array(survey.cards), responses.order(created_at: :desc))
    full       = +""
    ResultsReportGenerator.call(survey: survey, aggregated: aggregated, total: total) do |chunk|
      full << chunk
      yield chunk
    end
    if full.present?
      survey.update_columns(results_report: full, results_report_response_count: total)
    end
  end

  # Just the report body (Markdown → HTML) for the on-page preview, which styles
  # it for the dark results theme.
  def results_report_body_html(markdown)
    # kramdown's default parser covers the report's Markdown (## / ### headings,
    # bullet lists, bold) — no GFM-only features are used. The markdown is
    # model-generated and can fold in respondent free-text, so we sanitize the
    # rendered HTML rather than trusting it as raw (the sanitizer keeps the
    # report's formatting tags and drops scripts / event handlers).
    html = Kramdown::Document.new(markdown.to_s).to_html
    ActionController::Base.helpers.sanitize(html)
  end

  # A self-contained, light-themed HTML document — used for both the PDF
  # (wicked_pdf) and the Google Doc (Drive converts HTML → a Doc).
  def results_report_document(survey, markdown)
    render_to_string(
      template: "results_reports/document",
      formats:  [ :html ],
      layout:   false,
      locals:   {
        survey:       survey,
        body_html:    results_report_body_html(markdown),
        generated_at: Time.current
      }
    )
  end

  def results_report_filename(survey, ext)
    base = (survey.theme.presence || survey.title.presence || "verto").parameterize.presence || "verto"
    "#{base}-report.#{ext}"
  end
end
