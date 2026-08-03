# Denormalised columns for the two OPT-IN demographic questions (Heritage,
# Neurodiversity — DemographicQuestions::OPTIONAL_CARDS), mirroring
# AddDemographicsToResponses: answers live in the `answers` JSON keyed by a
# per-Verto card index, which no cross-Verto filter can query portably.
#
# demographic_neurodiversity is a multi-select packed as pipe-wrapped sorted
# canonical labels ("|ADHD|Dyslexia|"; the mutually-exclusive picks stored
# alone, "|None of these|") so one survey-scoped LIKE '%|label|%' counts a
# condition identically on SQLite and Postgres — no JSON functions, no
# array-column divergence between the two engines.
class AddOptionalDemographicsToResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :responses, :demographic_heritage, :string
    add_column :responses, :demographic_neurodiversity, :string
    add_index :responses, [ :survey_id, :demographic_heritage ]
    add_index :responses, [ :survey_id, :demographic_neurodiversity ]
  end
end
