class CreateFunders < ActiveRecord::Migration[8.0]
  def change
    create_table :funders do |t|
      t.references :organisation, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :seat_count, null: false, default: 0
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :funders, [ :organisation_id, :name ], unique: true

    create_table :funder_memberships do |t|
      t.references :funder, null: false, foreign_key: true
      t.references :organisation, null: false, foreign_key: true
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :funder_memberships, [ :funder_id, :organisation_id ], unique: true

    add_reference :invites, :funder, foreign_key: true
  end
end
