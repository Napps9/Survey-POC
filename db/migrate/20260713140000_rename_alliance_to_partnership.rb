class RenameAllianceToPartnership < ActiveRecord::Migration[8.1]
  def change
    rename_table :alliances, :partnerships
    rename_table :alliance_memberships, :partnership_memberships
    rename_table :alliance_vertos, :partnership_vertos
    rename_table :alliance_common_question_sets, :partnership_common_question_sets

    rename_column :partnership_memberships, :alliance_id, :partnership_id
    rename_column :partnership_vertos, :alliance_id, :partnership_id
    rename_column :partnership_common_question_sets, :alliance_id, :partnership_id
    rename_column :invites, :alliance_id, :partnership_id
    rename_column :survey_shares, :alliance_verto_id, :partnership_verto_id

    # rename_table / rename_column keep the old auto-generated index names in
    # both SQLite and Postgres — rename each explicitly. The memberships
    # composite gets a hand-shortened name: the Rails-style one would exceed
    # Postgres's 63-char identifier limit.
    rename_index :partnership_common_question_sets, "idx_alliance_cq_sets_unique", "idx_partnership_cq_sets_unique"
    rename_index :partnership_common_question_sets, "index_alliance_common_question_sets_on_alliance_id", "index_partnership_common_question_sets_on_partnership_id"
    rename_index :partnership_memberships, "index_alliance_memberships_on_alliance_id_and_organisation_id", "idx_partnership_memberships_partnership_org"
    rename_index :partnership_memberships, "index_alliance_memberships_on_alliance_id", "index_partnership_memberships_on_partnership_id"
    rename_index :partnership_memberships, "index_alliance_memberships_on_organisation_id", "index_partnership_memberships_on_organisation_id"
    rename_index :partnership_vertos, "index_alliance_vertos_on_alliance_id_and_survey_id", "index_partnership_vertos_on_partnership_id_and_survey_id"
    rename_index :partnership_vertos, "index_alliance_vertos_on_alliance_id", "index_partnership_vertos_on_partnership_id"
    rename_index :partnership_vertos, "index_alliance_vertos_on_survey_id", "index_partnership_vertos_on_survey_id"
    rename_index :partnerships, "index_alliances_on_organisation_id_and_name", "index_partnerships_on_organisation_id_and_name"
    rename_index :partnerships, "index_alliances_on_organisation_id", "index_partnerships_on_organisation_id"
    rename_index :invites, "index_invites_on_alliance_id", "index_invites_on_partnership_id"
    rename_index :survey_shares, "index_survey_shares_on_alliance_verto_id", "index_survey_shares_on_partnership_verto_id"
    rename_index :survey_shares, "index_survey_shares_on_av_and_partner", "index_survey_shares_on_pv_and_partner"
  end
end
