# The creator-facing anonymous names for respondent-code identities — the
# "Responder" column in the results export and the Responders card. Same
# assign-and-store contract as player_aliases: a name must never change once
# a creator has seen it, so the assignment is recorded the first time an
# identity is named, and there is no update path anywhere.
#
# code_digest is the responder grouping key (responses.respondent_code_digest).
# A separate table from player_aliases on purpose: the two digest kinds are
# deliberately unlinkable identities, and erasure purges each by its own kind.
class CreateRespondentAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :respondent_aliases do |t|
      t.references :survey, null: false, foreign_key: true
      t.string :code_digest, null: false
      t.string :anon_name, null: false
      t.timestamps
    end
    add_index :respondent_aliases, [ :survey_id, :code_digest ], unique: true
    add_index :respondent_aliases, [ :survey_id, :anon_name ], unique: true
  end
end
