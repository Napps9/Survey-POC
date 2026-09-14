# A respondent's linked Google (or later Apple/Microsoft) account.
#
# Deliberately NOT rows in `identities`. That table is `belongs_to :user` with
# a NOT NULL user_id, and PlayerAuthentication's header says why the two
# populations never share a table: Current#user delegates to Current.session,
# and OrganisationScope dereferences Current.user.memberships with no nil
# guard, so a Player reachable through anything the creator's side walks is a
# NoMethodError waiting for its first request. Separate cookie, separate table,
# separate Current attribute — and separate identities.
#
# (provider, uid) is unique because it is the canonical key: the address a
# provider reports can change, the uid cannot.
class CreatePlayerIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :player_identities do |t|
      t.references :player, null: false, foreign_key: true
      t.string  :provider, null: false
      t.string  :uid, null: false
      # What the provider said at the last sign-in, kept for support rather
      # than for lookup: the account's own address lives on players.
      t.string  :email
      t.string  :name
      t.timestamps
    end

    add_index :player_identities, [ :provider, :uid ], unique: true
  end
end
