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

    # Rails auto-renames every index whose name matches the conventional
    # generated pattern during the rename_table/rename_column calls above
    # (rename_table_indexes / rename_column_indexes — the PG adapter also
    # handles *_pkey and *_id_seq). Renaming them here again would target
    # names that no longer exist: SQLite's rename_index silently skips a
    # missing old name, but Postgres's is a raw ALTER INDEX and raises —
    # which is how the first version of this migration crash-looped the
    # production deploy. Only the two CUSTOM-named indexes below are left
    # behind by the auto-rename and need renaming by hand.
    #
    # The memberships composite index deliberately keeps the hashed name the
    # auto-rename gave it (idx_on_partnership_id_organisation_id_292249422a,
    # recorded in schema.rb): its conventional renamed form would exceed
    # Postgres's 63-char identifier limit, and the hash is derived from the
    # column names, so it is identical on every adapter.
    rename_index :partnership_common_question_sets, "idx_alliance_cq_sets_unique", "idx_partnership_cq_sets_unique"
    rename_index :survey_shares, "index_survey_shares_on_av_and_partner", "index_survey_shares_on_pv_and_partner"
  end
end
