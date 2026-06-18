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

  # Just the report body (Markdown → HTML) for the on-page preview, which styles
  # it for the dark results theme.
  def results_report_body_html(markdown)
    # kramdown's default parser covers the report's Markdown (## / ### headings,
    # bullet lists, bold) — no GFM-only features are used.
    Kramdown::Document.new(markdown.to_s).to_html.html_safe
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
