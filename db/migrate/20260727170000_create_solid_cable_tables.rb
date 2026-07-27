class CreateSolidCableTables < ActiveRecord::Migration[8.1]
  # Solid Cable's schema in the PRIMARY database, for the same reason Solid
  # Queue's is: one small Render Postgres, where a second connection pool
  # against the same server would spend connections for no isolation.
  #
  # Generated from db/cable_schema.rb (solid_cable 3.0.12), unmodified apart
  # from being wrapped in a migration.
  def change
    create_table "solid_cable_messages", force: :cascade do |t|
      t.binary "channel", limit: 1024, null: false
      t.binary "payload", limit: 536870912, null: false
      t.datetime "created_at", null: false
      t.integer "channel_hash", limit: 8, null: false
      t.index [ "channel" ], name: "index_solid_cable_messages_on_channel"
      t.index [ "channel_hash" ], name: "index_solid_cable_messages_on_channel_hash"
      t.index [ "created_at" ], name: "index_solid_cable_messages_on_created_at"
    end
  end
end
