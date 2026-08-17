class AddKindToReportRenders < ActiveRecord::Migration[8.1]
  # A second document a survey's report_renders can produce: a compact,
  # figures-only "share card" alongside the existing full prose report. Both
  # are still PDFs (see RenderInfographicJob's own comment for why "PNG
  # infographic" didn't ship) — kind describes the DOCUMENT'S PURPOSE, not its
  # file format, which is why it isn't named after one.
  def change
    add_column :report_renders, :kind, :string, null: false, default: "report"

    # Mirrors the existing chk_report_renders_status constraint (db/schema.rb)
    # — a console session or bulk update bypassing the model's own enum
    # validation shouldn't be able to write an unrecognised kind either.
    add_check_constraint :report_renders, "kind IN ('report', 'infographic')",
      name: "chk_report_renders_kind"
  end
end
