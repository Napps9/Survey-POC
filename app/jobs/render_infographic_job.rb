# Renders a survey's share card away from the request thread — the compact,
# figures-only sibling of RenderReportPdfJob's full prose report.
#
# No AI step, unlike the full report: the share card is pure figures
# (ReportChartRows against the responses themselves), so it needs nothing
# cached on the survey first and never touches ResultsReportGenerator. It can
# be requested even for a Verto that has never generated an AI report at all.
class RenderInfographicJob < ApplicationJob
  include GeneratesResultsReport

  queue_as :default

  discard_on StandardError do |job, error|
    render = ReportRender.find_by(id: job.arguments.first)
    ErrorReporting.report("RenderInfographicJob", error, report_render_id: render&.id)
    render&.fail!("We couldn't build that share card — please try again.")
  end

  def perform(report_render_id)
    render = ReportRender.find_by(id: report_render_id)
    return unless render
    # "running" is a previous attempt whose process died mid-render, not a
    # duplicate — see RenderReportPdfJob. Redo it.
    return if render.finished?

    render.start!
    survey = render.survey

    html = render_to_string(
      template: "results_reports/infographic",
      formats:  [ :html ],
      layout:   false,
      locals:   {
        survey:     survey,
        stats:      ReportChartRows.summary_stats(survey),
        aggregated: report_figures_for(survey)
      }
    )
    pdf = render_infographic_pdf(html)

    render.document.attach(
      io:           StringIO.new(pdf),
      filename:     results_report_filename(survey, "pdf"),
      content_type: "application/pdf"
    )
    render.succeed!
  end

  # GeneratesResultsReport builds the document with render_to_string, which is
  # a controller/view concern — a job has no view context of its own, so lend
  # it one (mirrors RenderReportPdfJob).
  def render_to_string(...)
    ApplicationController.render(...)
  end
end
