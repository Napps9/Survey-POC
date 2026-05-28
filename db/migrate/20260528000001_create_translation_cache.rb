class CreateTranslationCache < ActiveRecord::Migration[8.1]
  def change
    create_table :translation_cache do |t|
      t.string :source_hash, null: false
      t.string :source_locale, null: false
      t.string :target_locale, null: false
      t.json   :translation,  null: false
      t.timestamps
    end
    add_index :translation_cache,
              [ :source_hash, :source_locale, :target_locale ],
              unique: true,
              name: "idx_translation_cache_lookup"
  end
end
