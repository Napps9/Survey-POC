# A signed-in respondent's session, in the shape of `sessions` — no token
# column, because the signed permanent cookie carries the row id.
#
# A separate table and a separate cookie (`player_session_id`) from the
# creator's. Current#user delegates to Current.session and
# OrganisationScope#set_current_organisation dereferences
# Current.user.memberships with no nil guard, so overloading the creator's
# session with a respondent would NoMethodError on the first request.
class CreatePlayerSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :player_sessions do |t|
      t.references :player, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.timestamps
    end
  end
end
