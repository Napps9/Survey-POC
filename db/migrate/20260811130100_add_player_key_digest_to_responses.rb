# The durable per-Verto player identity behind the leaderboard's stable
# anonymous names.
#
# The session token lives in sessionStorage and dies with the tab, so it can't
# tie a retake to the person's earlier runs. The player mints a second UUID in
# localStorage (per Verto, only while the leaderboard is on) and sends it with
# every write; the server stores it only as this per-survey HMAC — the same
# pattern and reasoning as respondent_code_digest: never the raw value, and a
# digest is comparable only within one Verto, so identities can't be joined
# across surveys.
#
# Nullable, because it is recorded only while the leaderboard is active, and
# every response from before the feature has none. The index is NOT unique —
# several responses per digest is the whole point (retakes).
class AddPlayerKeyDigestToResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :responses, :player_key_digest, :string
    add_index :responses, [ :survey_id, :player_key_digest ],
              name: "index_responses_on_survey_and_player_key"
  end
end
