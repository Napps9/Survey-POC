class CreateVertoBuilds < ActiveRecord::Migration[8.1]
  # Tracks one in-flight Verto generation so the wizard can hand the work to a
  # background job and poll for it, instead of holding a Puma request thread for
  # the 30-120s a Claude generation takes (P0-3).
  #
  # State lives in a table rather than Rails.cache on purpose: the cache store
  # here is still per-process memory on an ephemeral disk (P0-5), so a poll could
  # land on a process that has never heard of the build.
  def change
    create_table :verto_builds do |t|
      t.references :organisation, null: false, foreign_key: true
      t.references :user,         null: false, foreign_key: true
      # nil until the job succeeds; this is what the poller redirects to.
      t.references :survey,       null: true,  foreign_key: true

      t.string :status, null: false, default: "pending"
      # The wizard's answers, replayed by the job. Small: a few strings, a locale
      # list, a palette and the picked Common Question ids.
      t.json   :payload, null: false, default: {}
      # Creator-facing failure text, already passed through friendly_generate_error.
      t.text   :error_message

      t.timestamps
    end

    # The poller reads the caller's most recent build; the sweeper reads old ones.
    add_index :verto_builds, [ :organisation_id, :created_at ]
    add_index :verto_builds, :status
  end
end
