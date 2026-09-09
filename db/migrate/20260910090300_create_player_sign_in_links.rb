# One emailed sign-in link. A row rather than `generates_token_for`, for
# three reasons that only show up once a link has to be single-use:
#
#   * Single use has to be ATOMIC. Rotating a salt in a generates_token_for
#     block is the repo's idiom (User#password_reset), but a double-tap
#     verifies twice against the pre-rotation salt and starts two sessions.
#     `consumed_at` with a conditional UPDATE cannot do that.
#   * Rotating a salt invalidates EVERY outstanding link for that person.
#     Harmless for a password reset, which follows a deliberate password
#     change; here it means "ask for a second link, click the first one, it's
#     dead", which is an ordinary thing for a person to do.
#   * The link carries what it is for. claim_payload holds the Vertos this
#     sign-in should attach, so nothing is written against an address until
#     someone proves they can read it.
#
# Only the digest is stored, never the token — the respondent_code_digest
# discipline. A leaked database row cannot be turned back into a working link.
class CreatePlayerSignInLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :player_sign_in_links do |t|
      t.references :player, null: false, foreign_key: true
      t.string   :token_digest, null: false
      # [{ "response_id" => 2, "source" => "signup" }, …]. The response names
      # its own survey, so the survey id is not carried: a payload that stated
      # one could disagree with the row it points at.
      t.json     :claim_payload, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end

    add_index :player_sign_in_links, :token_digest, unique: true
    # The sweep: spent and expired links are worth keeping only long enough to
    # tell someone their link has already been used.
    add_index :player_sign_in_links, :expires_at
  end
end
