# Follow-up: drop `responses.demographic_neurodiversity`

This is **deploy 2** of the Neurodiversity withdrawal. It is deliberately not in
the same release as the purge, and must not be merged until the purge is live.

## Why it waits

`PurgeContactAndNeurodiversityCards` nulls every value in the column, and
`Response.ignored_columns` stops the new code reading or writing it. The column
itself is still there on purpose: Render swaps processes **after** migrations
run, so dropping it in the same release would leave the outgoing process issuing
`INSERT`/`SELECT` against a column that had just disappeared — a `PG::UndefinedColumn`
on every `/progress` write for the length of the swap, which is an outage for
respondents mid-play.

Once the purge release is live in production, every running process is already
ignoring the column and the drop is safe.

## What to ship

Add this migration, run `bin/rails db:migrate` to regenerate `db/schema.rb`, and
remove the `self.ignored_columns` line from `app/models/response.rb` in the
release *after* this one.

```ruby
class RemoveNeurodiversityColumnFromResponses < ActiveRecord::Migration[8.1]
  def up
    remove_index  :responses, [ :survey_id, :demographic_neurodiversity ],
                  name: "index_responses_on_survey_id_and_demographic_neurodiversity",
                  if_exists: true
    remove_column :responses, :demographic_neurodiversity
  end

  def down
    add_column :responses, :demographic_neurodiversity, :string
    add_index  :responses, [ :survey_id, :demographic_neurodiversity ],
               name: "index_responses_on_survey_id_and_demographic_neurodiversity"
  end
end
```

Reversible as schema; the data it held was deliberately destroyed and does not
come back.
