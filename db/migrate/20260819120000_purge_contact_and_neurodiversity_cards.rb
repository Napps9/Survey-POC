class PurgeContactAndNeurodiversityCards < ActiveRecord::Migration[8.1]
  # Takes the withdrawn `contact_form` and Neurodiversity cards out of every
  # Verto and drops the answers they collected. The removal itself (including
  # the answer re-key that keeps every surviving answer pointing at the card it
  # was given for) lives in LegacyCardPurge, so it can be unit tested.
  #
  # Survey has no default scope — only `scope :kept` — so find_each reaches
  # soft-deleted Vertos too, which is the point: the data has to be gone from
  # those as well.

  # Response declares demographic_neurodiversity in ignored_columns (it is
  # dropped a deploy later), so the real model can no longer write it. This
  # throwaway class sees the column the schema still has.
  class ResponseRow < ActiveRecord::Base
    self.table_name = "responses"
  end

  def up
    Survey.reset_column_information
    ResponseRow.reset_column_information

    removed = 0
    Survey.find_each { |survey| removed += LegacyCardPurge.purge_survey!(survey) }
    say "removed #{removed} withdrawn card(s) from surveys"

    nulled = ResponseRow.where.not(demographic_neurodiversity: nil)
                        .update_all(demographic_neurodiversity: nil)
    say "cleared #{nulled} denormalised neurodiversity value(s)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "the withdrawn cards and the answers they collected are deleted, not archived"
  end
end
