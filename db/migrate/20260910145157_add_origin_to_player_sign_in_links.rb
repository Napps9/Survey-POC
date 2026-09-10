# Where a sign-in link came from, because only one of the two answers proves
# anything about the address.
#
# A link that travelled through an inbox is proof the person can read that
# address — that is what stamps Player#email_verified_at, and what
# PlayerAudience.for_survey requires before it will mail anyone. A link handed
# straight back in the join response proves only that somebody typed the
# address into a form, so it must NOT verify.
#
# Defaults to "email": every row that exists when this runs was mailed.
class AddOriginToPlayerSignInLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :player_sign_in_links, :origin, :string, null: false, default: "email"
  end
end
