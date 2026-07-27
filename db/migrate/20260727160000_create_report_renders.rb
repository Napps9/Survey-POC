class CreateReportRenders < ActiveRecord::Migration[8.1]
  # One PDF build of a results report.
  #
  # Rendering used to happen inside the download request: wkhtmltopdf spawns a
  # native process that transiently uses 100-200MB, and because two at once can
  # OOM the 512MB instance it was serialized behind a process-wide mutex. That
  # capped peak memory but not thread occupancy — a second download sat on a
  # Puma thread waiting for the lock, which is the same failure the rest of P0-3
  # is about. Rendering in a job removes both: the spike leaves the web process,
  # and nobody waits on a thread for it.
  def change
    create_table :report_renders do |t|
      t.references :survey, null: false, foreign_key: true
      t.references :user,   null: false, foreign_key: true

      t.string :status, null: false, default: "pending"
      t.text   :error_message

      t.timestamps
    end

    # The sweeper reads old finished renders; the poller reads its own by id.
    add_index :report_renders, [ :status, :created_at ]
  end
end
