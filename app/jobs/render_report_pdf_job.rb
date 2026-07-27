# Renders a results report to PDF away from the request thread.
#
# The AI step doesn't run here — the report markdown is cached on the survey and
# was generated before the download was ever offered. This job is purely the
# wkhtmltopdf render, which is the memory-heavy part.
class RenderReportPdfJob < ApplicationJob
  include GeneratesResultsReport

  queue_as :default

  discard_on StandardError do |job, error|
    render = ReportRender.find_by(id: job.arguments.first)
    ErrorReporting.report("RenderReportPdfJob", error, report_render_id: render&.id)
    render&.fail!("We couldn't build that PDF — please try again.")
  end

  def perform(report_render_id)
    render = ReportRender.find_by(id: report_render_id)
    return unless render
    return if render.finished? || render.status == "running"

    render.start!
    survey = render.survey

    pdf = render_report_pdf(
      results_report_document(survey, results_report_markdown(survey)),
      page_size: "A4",
      margin:    { top: 14, bottom: 16, left: 14, right: 14 }
    )

    render.document.attach(
      io:           StringIO.new(pdf),
      filename:     results_report_filename(survey, "pdf"),
      content_type: "application/pdf"
    )
    render.succeed!
  end

  # GeneratesResultsReport builds the document with render_to_string, which is a
  # controller/view concern — a job has no view context of its own, so lend it
  # one. ApplicationController is the right base: the report template reads the
  # same helpers it does when rendered from a request.
  def render_to_string(...)
    ApplicationController.render(...)
  end
end
