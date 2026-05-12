class CreateAlliances < ActiveRecord::Migration[8.1]
  def change
    create_table :alliances do |t|
      t.references :organisation, null: false, foreign_key: true
      t.references :partner_organisation, null: false, foreign_key: { to_table: :organisations }
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :alliances, [ :organisation_id, :partner_organisation_id ], unique: true, name: "index_alliances_on_org_and_partner"
  end
end
