require "csv"

# GET /surveys/:survey_id/results/export?kind=responses|summary&segment=…
# Streams the Verto's results as a CSV download. `kind` picks the raw-responses
# table or the aggregated summary; `segment` matches the on-screen filter.
class ResultsExportsController < ApplicationController
  include PreparesResultsExport

  def show
    survey          = export_survey
    export, _active = build_results_export(survey, params[:segment])

    summary  = params[:kind].to_s == "summary"
    label    = summary ? "summary" : "responses"
    filename = "verto-#{survey.id}-#{label}-#{Date.current.iso8601}.csv"

    response.headers["Content-Type"]        = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: filename)
    response.headers["X-Accel-Buffering"]   = "no"

    # Stream the CSV row-by-row so neither the full table nor the generated CSV
    # string is held in memory; raw-response rows are pulled from the DB in
    # batches inside export.each_row. Lead with a UTF-8 BOM for Excel.
    self.response_body = Enumerator.new do |out|
      out << "﻿"
      export.each_row(summary: summary) { |row| out << CSV.generate_line(row) }
    end
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    ErrorReporting.report("ResultsExportsController", e)
    redirect_to survey_results_path(params[:survey_id]), alert: "Couldn't export results — #{e.message}"
  end
end
