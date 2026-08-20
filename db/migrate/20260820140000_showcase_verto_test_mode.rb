# Puts the showcase Verto into Test Mode on an EXISTING database.
#
# The migration two before this one provisioned the showcase Verto, and in its
# first revision it published it — a /play link, the editor locked, and a real
# collection surface for a deck that exists to be handed round and edited. Test
# Mode is what that deck actually wants: /test/:token plays the real thing
# without sign-in, records NOTHING, and keeps the deck editable.
#
# A create-only provisioner can't fix a Verto that already exists, so this is a
# second, separate step rather than an edit to that migration — any deploy that
# already ran it has the published version, and editing a migration that has
# run changes nothing.
#
# Idempotent and safe from either side: ensure_test_mode! provisions the Verto
# if it is missing, mints the test link only if there isn't one already (that
# URL may be in somebody's hands), and unpublishes only if it is live. With no
# responses collected, coming off /play returns it to a fully editable draft.
class ShowcaseVertoTestMode < ActiveRecord::Migration[8.0]
  def up
    Survey.reset_column_information
    ShowcaseVertoSeeder.new.ensure_test_mode!
  rescue => e
    # Data-only migration: model drift must not hold a deploy hostage — the
    # same step is `bin/rails showcase:test_mode`.
    say "Showcase Verto Test Mode conversion skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing — publishing is a deliberate act, not a rollback.
  end
end
