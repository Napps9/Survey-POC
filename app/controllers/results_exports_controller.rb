require "csv"

# GET /surveys/:survey_id/results/export?kind=responses|summary&segment=…
# Streams the Verto's results as a CSV download. `kind` picks the raw-responses
# table or the aggregated summary; `segment` matches the on-screen filter.
class ResultsExportsController < ApplicationController
  include PreparesResultsExport

  def show
    survey         = export_survey
    export, _active = build_results_export(survey, params[:segment])

    summary = params[:kind].to_s == "summary"
    rows    = summary ? export.summary_rows : export.response_rows
    label   = summary ? "summary" : "responses"

    # Lead with a UTF-8 BOM so Excel reads accented text correctly.
    csv = +"﻿"
    csv << CSV.generate { |out| rows.each { |row| out << row } }

    send_data csv,
      filename:    "verto-#{survey.id}-#{label}-#{Date.current.iso8601}.csv",
      type:        "text/csv; charset=utf-8",
      disposition: "attachment"
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    Rails.logger.error("[ResultsExportsController] #{e.class}: #{e.message}")
    redirect_to survey_results_path(params[:survey_id]), alert: "Couldn't export results — #{e.message}"
  end
end
