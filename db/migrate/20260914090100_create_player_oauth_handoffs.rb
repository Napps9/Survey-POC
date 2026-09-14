# What a respondent's run is worth, parked for the length of a Google round
# trip.
#
# PlayerSignInLink already carries a claim payload across a gap, but it
# `belongs_to :player` and at this point in the flow there is no player yet:
# nobody knows the address until Google reports one. Hence a row of its own,
# owned by nothing, that the callback trades in for the claims it was minted
# with.
#
# Why a row at all, rather than the session? Because the payload is computed
# from what the PLAYER PAGE knows — the run's session_token and this device's
# leaderboard keys — and that page is service-worker cached, posts without a
# CSRF token, and runs its join under `protect_from_forgery with:
# :null_session`, where a cookie write is a silently dropped no-op. It cannot
# put anything in a session. So it hands the claims to the server, gets an
# opaque token back, and the /you/ page it navigates to (outside the worker's
# scope, with a live token) is where the session starts.
#
# Same three disciplines as PlayerSignInLink, for the same reasons: only the
# digest is stored, single use is an atomic conditional UPDATE rather than a
# read-check-write, and it expires.
class CreatePlayerOauthHandoffs < ActiveRecord::Migration[8.1]
  def change
    create_table :player_oauth_handoffs do |t|
      t.string :token_digest, null: false
      # [{ "response_id" => 2, "source" => "signup" }, …] — the same shape
      # player_sign_in_links.claim_payload carries, spent through the same
      # PlayerClaimPayload.apply.
      t.json :claim_payload, null: false, default: []
      # Which Verto sent them, for the "back to the Verto" link when Google
      # hands back nothing usable. Nullable and nullify-on-delete: a deleted
      # Verto must not strand a handoff mid-flight.
      t.references :survey, null: true, foreign_key: { on_delete: :nullify }
      t.string :locale
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end

    add_index :player_oauth_handoffs, :token_digest, unique: true
    # Every lookup is `live` — unconsumed AND unexpired — so this is the half
    # of that predicate a range can serve. (It is also what a sweep would want.
    # There isn't one yet, here or on player_sign_in_links; these rows are tiny
    # and hold no address, so the case for writing one is housekeeping rather
    # than exposure.)
    add_index :player_oauth_handoffs, :expires_at
  end
end
