class AddOrganisationToSurveys < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:surveys, :organisation_id)
    add_reference :surveys, :organisation, null: true, foreign_key: true
    execute <<~SQL
      UPDATE surveys SET organisation_id = (SELECT id FROM organisations LIMIT 1)
      WHERE organisation_id IS NULL
    SQL
    change_column_null :surveys, :organisation_id, false
  end

  def down
    remove_reference :surveys, :organisation
  end
end
