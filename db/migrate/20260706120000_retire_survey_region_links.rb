class RetireSurveyRegionLinks < ActiveRecord::Migration[8.1]
  def up
    remove_column :responses, :survey_region_link_id, :integer if column_exists?(:responses, :survey_region_link_id)
    remove_column :surveys, :ask_region, :boolean if column_exists?(:surveys, :ask_region)
    drop_table :survey_region_links if table_exists?(:survey_region_links)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
