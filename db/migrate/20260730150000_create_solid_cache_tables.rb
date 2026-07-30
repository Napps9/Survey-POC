class CreateSolidCacheTables < ActiveRecord::Migration[8.1]
  # Solid Cache's schema in the PRIMARY database, for the same reason Solid
  # Queue's and Solid Cable's are: one small Render Postgres, where a second
  # connection pool against the same server would spend connections for no
  # isolation.
  #
  # Generated from db/cache_schema.rb (solid_cache 1.0.10), unmodified apart
  # from being wrapped in a migration.
  def change
    create_table "solid_cache_entries", force: :cascade do |t|
      t.binary "key", limit: 1024, null: false
      t.binary "value", limit: 536870912, null: false
      t.datetime "created_at", null: false
      t.integer "key_hash", limit: 8, null: false
      t.integer "byte_size", limit: 4, null: false
      t.index [ "byte_size" ], name: "index_solid_cache_entries_on_byte_size"
      t.index [ "key_hash", "byte_size" ], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
      t.index [ "key_hash" ], name: "index_solid_cache_entries_on_key_hash", unique: true
    end
  end
end
