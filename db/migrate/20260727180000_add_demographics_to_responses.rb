class AddDemographicsToResponses < ActiveRecord::Migration[8.1]
  # Denormalised demographic answers, so results can be sliced by them.
  #
  # The alternative — querying the answers JSON — is both dialect-specific
  # (Postgres `->>` vs SQLite json_extract) and keyed by a card index that
  # differs per Verto, so a filter would have to be rewritten per survey. Region
  # was denormalised for exactly this reason; these follow it.
  #
  # Only the two set demographic questions that produce a small, stable set of
  # values. Free-text answers stay in the JSON: they aren't filter dimensions.
  def change
    add_column :responses, :demographic_gender, :string
    # Year only, not the full birth date: a filter needs age bands, and storing
    # less of a respondent's date of birth than we're given is the right default
    # for a column that exists to be grouped.
    add_column :responses, :demographic_birth_year, :integer

    add_index :responses, [ :survey_id, :demographic_gender ]
    add_index :responses, [ :survey_id, :demographic_birth_year ]
  end
end
