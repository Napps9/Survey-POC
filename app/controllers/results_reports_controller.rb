# The downloadable AI results report. JSON returns the rendered report body for
# the on-page preview; PDF streams the report as a file (wicked_pdf). Both reuse
# the generate-and-cache helper in GeneratesResultsReport. PATCH saves the
# creator's hand-edited markdown over the cached AI text.
class ResultsReportsController < ApplicationController
  include GeneratesResultsReport

  # Persist an edited report. Syncing results_report_response_count to the
  # CURRENT completed count is what keeps the edit alive: the count-keyed cache
  # only regenerates (overwriting the edit) once responses genuinely change
  # again — not on the next page view because the count had already drifted
  # between generation and the edit.
  def update
    survey   = Current.organisation.surveys.find(params[:survey_id])
    markdown = params[:markdown].to_s
    if markdown.strip.blank?
      return render json: { ok: false, error: "The report can't be empty." }, status: :unprocessable_entity
    end

    total = survey.responses.where(status: "completed").count
    survey.update_columns(
      results_report:                markdown,
      results_report_response_count: total,
      results_report_edited_at:      Time.current,
      updated_at:                    Time.current
    )
    render json: { ok: true, body_html: results_report_body_html(markdown) }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Verto not found." }, status: :not_found
  end

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
    ErrorReporting.report("ResultsReportsController", e)
    respond_to do |format|
      format.json { render json: { ok: false, error: "Couldn't generate the report — please try again." }, status: :unprocessable_entity }
      format.pdf  { head :internal_server_error }
    end
  end
end
