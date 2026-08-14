# Ask Verto dates every result it cites — "research collected in 2023 found…" —
# and that window is a MIN(created_at)/MAX(created_at) over the survey's
# answered responses, asked once per Verto per turn.
#
# `index_responses_on_survey_answered_status` satisfies the WHERE but stops
# there: created_at isn't in it, so the planner reads every matching row to find
# the endpoints. On the WLL Transforming Education import that is 50,835 rows,
# twice, for a string that reads "Mar 2021 – Aug 2022".
#
# With created_at trailing the same two columns, MIN and MAX are index-endpoint
# lookups. CorpusIndexer walks the same scope, so it benefits too.
class AddFieldedWindowIndexToResponses < ActiveRecord::Migration[8.1]
  def change
    add_index :responses, [ :survey_id, :answered, :created_at ],
              name: "index_responses_on_survey_answered_created_at"
  end
end
