# A respondent account is now reached by choosing a password at the end of a
# Verto, rather than by waiting for a link to arrive in an inbox.
#
# NULLABLE, and permanently so. Players created before this change have no
# password — the emailed link was the only way in — and PlayerSignInLink is
# deliberately still here as the recovery route, so Player.for_email goes on
# creating passwordless rows. A NOT NULL column would break both.
class AddPasswordDigestToPlayers < ActiveRecord::Migration[8.1]
  def change
    add_column :players, :password_digest, :string
  end
end
