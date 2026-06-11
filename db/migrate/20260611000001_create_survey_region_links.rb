class CreateSurveyRegionLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :survey_region_links do |t|
      t.integer :survey_id, null: false
      t.string  :country_code, null: false
      t.string  :label
      t.string  :token, null: false
      t.timestamps
    end
    add_index :survey_region_links, :survey_id
    add_index :survey_region_links, :token, unique: true
    add_index :survey_region_links, [ :survey_id, :country_code, :label ],
              unique: true, name: "idx_region_links_unique_region"

    # Region attribution on responses: the link the respondent arrived through
    # (or matched by self-selection), plus denormalised country/label so
    # aggregation never needs the link row.
    add_column :responses, :survey_region_link_id, :integer
    add_column :responses, :region_country, :string
    add_column :responses, :region_label, :string
    add_index  :responses, :survey_region_link_id
  end
end
