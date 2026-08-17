# Asks for a results report as a PDF, watches it build, and serves the file.
#
# The render is a background job because wkhtmltopdf spawns a native process
# using 100-200MB transiently. It used to run inside the download request behind
# a process-wide mutex, which capped peak memory but left a second download
# sitting on a Puma thread waiting for the lock.
class ReportRendersController < ApplicationController
  # POST /surveys/:survey_id/results/report/renders
  def create
    survey = Current.organisation.surveys.find(params[:survey_id])
    kind = ReportRender::KINDS.include?(params[:kind].to_s) ? params[:kind].to_s : "report"
    render_row = survey.report_renders.create!(user: Current.user, kind: kind)
    job_for(kind).perform_later(render_row.id)

    render json: { ok: true, id: render_row.id, poll_url: report_render_path(render_row) }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Verto not found." }, status: :not_found
  end

  # GET /report_renders/:id
  def show
    render_row = find_render

    # A render whose job died — this instance restarts its worker at 85% RSS,
    # and a PDF render is exactly the spike that trips it. Surface it instead of
    # letting the browser poll a "running" row forever.
    render_row.fail!("That took longer than expected. Please try again.") if render_row.stale?

    payload = { ok: true, status: render_row.status }
    payload[:download_url] = download_report_render_path(render_row) if render_row.succeeded?
    payload[:error]        = render_row.error_message if render_row.failed?
    render json: payload
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "That download expired — please try again." }, status: :not_found
  end

  # GET /report_renders/:id/download
  def download
    render_row = find_render
    return head :not_found unless render_row.succeeded? && render_row.document.attached?

    send_data render_row.document.download,
              filename:    render_row.document.filename.to_s,
              type:        render_row.document.content_type,
              disposition: "attachment"
  end

  private

  def job_for(kind)
    kind == "infographic" ? RenderInfographicJob : RenderReportPdfJob
  end

  # Scoped through the org's surveys, so a render id from another account is
  # simply not found — the same rule every other results path follows.
  def find_render
    ReportRender.joins(:survey)
                .where(surveys: { organisation_id: Current.organisation.id })
                .find(params[:id])
  end
end
