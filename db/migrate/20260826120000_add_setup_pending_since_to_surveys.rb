# When a Verto is created by IMPORT (PDF, Google Forms) the creator lands in the
# editor immediately and FinishVertoSetupJob fills in imagery and translations
# behind them. Nothing recorded that this was happening, which is what let the
# editor's autosave — which rebuilds the deck from the DOM, and the DOM has no
# pictures in it yet — write an image-less deck straight over the job's work.
#
# Nullable with no backfill, deliberately: NULL means "not in setup", which is
# the truth for every Verto that already exists and for every creation path
# except the import. Only SurveysController#create_imported_survey! ever sets
# it, and FinishVertoSetupJob clears it in an `ensure` so a job the memory
# watchdog kills can't leave the flag standing.
class AddSetupPendingSinceToSurveys < ActiveRecord::Migration[8.0]
  def change
    add_column :surveys, :setup_pending_since, :datetime
  end
end
