# The downloadable AI results report. JSON returns the rendered report body for
# the on-page preview; PDF streams the report as a file (wicked_pdf). Both reuse
# the generate-and-cache helper in GeneratesResultsReport.
class ResultsReportsController < ApplicationController
  include GeneratesResultsReport

  def show
    survey   = Current.organisation.surveys.find(params[:survey_id])
    markdown = results_report_markdown(survey)

    respond_to do |format|
      format.json do
        render json: { ok: true, body_html: results_report_body_html(markdown) }
      end
      format.pdf do
        pdf = render_report_pdf(
          results_report_document(survey, markdown),
          page_size: "A4",
          margin:    { top: 14, bottom: 16, left: 14, right: 14 }
        )
        send_data pdf,
          filename:    results_report_filename(survey, "pdf"),
          type:        "application/pdf",
          disposition: "attachment"
      end
    end
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.json { render json: { ok: false, error: "Verto not found." }, status: :not_found }
      format.pdf  { head :not_found }
    end
  rescue => e
    Rails.logger.error("[ResultsReportsController] #{e.class}: #{e.message}")
    respond_to do |format|
      format.json { render json: { ok: false, error: "Couldn't generate the report — please try again." }, status: :unprocessable_entity }
      format.pdf  { head :internal_server_error }
    end
  end
end
