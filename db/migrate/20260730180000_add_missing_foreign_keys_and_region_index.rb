class AddMissingForeignKeysAndRegionIndex < ActiveRecord::Migration[8.1]
  # P1-9. Three belongs_to columns had no referential integrity behind them, so
  # a raw DELETE (a console session, a partial restore, a future bulk cleanup)
  # could leave rows pointing at nothing. Every one has a `dependent:` on the
  # Rails side, which only holds while deletes go through Active Record.
  #
  # The plan named only identities.user_id; the other two came out of walking
  # every *_id column against the existing add_foreign_key list.
  #
  # Ordering note for deploy: CommonQuestionSet gained
  # `has_many :partnership_common_question_sets, dependent: :destroy` in the
  # same change. Without it this migration would make destroying a shared
  # Common Question set raise instead of silently orphaning its join rows.
  def change
    add_foreign_key :identities, :users
    add_foreign_key :partnership_common_question_sets, :partnerships
    add_foreign_key :partnership_common_question_sets, :common_question_sets

    # The public regions endpoint filters exactly on this pair:
    #   responses.where(survey_id:, answered: true).where.not(region_country: nil)
    # The existing [survey_id, answered, status] index stops at survey_id for
    # this query. region_label is deliberately NOT in the index — PlayerController
    # #regions groups by country only and never filters on the label.
    add_index :responses, [ :survey_id, :region_country ],
              name: "index_responses_on_survey_and_region_country"
  end
end
