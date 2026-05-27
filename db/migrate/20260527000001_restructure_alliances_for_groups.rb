class RestructureAlliancesForGroups < ActiveRecord::Migration[8.1]
  def up
    # Wipe partner-related data: this is a POC and the schema shift is
    # incompatible with the existing 1:1 rows.
    execute "DELETE FROM responses WHERE survey_share_id IS NOT NULL"
    execute "DELETE FROM survey_shares"
    execute "DELETE FROM invites WHERE kind = 'partner'"
    execute "DELETE FROM alliances"

    # ── alliances: become a named group owned by one creator org ──
    remove_index :alliances, name: :index_alliances_on_org_and_partner if index_exists?(:alliances, [:organisation_id, :partner_organisation_id], name: :index_alliances_on_org_and_partner)
    remove_index :alliances, name: :index_alliances_on_partner_organisation_id if index_exists?(:alliances, :partner_organisation_id)
    remove_foreign_key :alliances, column: :partner_organisation_id
    remove_column :alliances, :partner_organisation_id

    add_column :alliances, :name, :string
    execute "UPDATE alliances SET name = 'Alliance ' || id WHERE name IS NULL"
    change_column_null :alliances, :name, false
    add_index :alliances, [:organisation_id, :name], unique: true

    # ── alliance_memberships: partner orgs in an alliance ──
    create_table :alliance_memberships do |t|
      t.references :alliance, null: false, foreign_key: true
      t.references :organisation, null: false, foreign_key: true
      t.string :status, default: "active", null: false
      t.timestamps
    end
    add_index :alliance_memberships, [:alliance_id, :organisation_id], unique: true

    # ── alliance_vertos: which surveys are part of which alliance ──
    create_table :alliance_vertos do |t|
      t.references :alliance, null: false, foreign_key: true
      t.references :survey, null: false, foreign_key: true
      t.timestamps
    end
    add_index :alliance_vertos, [:alliance_id, :survey_id], unique: true

    # ── survey_shares: keyed by (alliance_verto, partner_org) ──
    remove_index :survey_shares, name: :index_survey_shares_on_survey_id_and_alliance_id if index_exists?(:survey_shares, [:survey_id, :alliance_id], name: :index_survey_shares_on_survey_id_and_alliance_id)
    remove_index :survey_shares, name: :index_survey_shares_on_alliance_id if index_exists?(:survey_shares, :alliance_id)
    remove_foreign_key :survey_shares, :alliances
    remove_column :survey_shares, :alliance_id
    remove_column :survey_shares, :label

    add_reference :survey_shares, :alliance_verto, null: false, foreign_key: true
    add_reference :survey_shares, :partner_organisation, null: false, foreign_key: { to_table: :organisations }
    add_index :survey_shares, [:alliance_verto_id, :partner_organisation_id], unique: true, name: :index_survey_shares_on_av_and_partner

    # ── invites: partner invites now target a specific alliance ──
    add_reference :invites, :alliance, foreign_key: true

    # ── organisations.kind goes away — every org is a peer ──
    remove_column :organisations, :kind
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
