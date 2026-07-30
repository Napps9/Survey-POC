# An optional self-invented code a respondent can give, so the same person's
# answers can be linked across waves of the same Verto without anyone being
# identified.
#
# What's stored is an HMAC, never the code. The key is derived per survey, so a
# digest is only comparable WITHIN one Verto — the same code given to two
# different Vertos produces two unrelated digests, and a creator with database
# access still can't read anyone's code or recognise them elsewhere.
#
# No unique index: repeat participation is the entire point, so several responses
# legitimately share a digest. session_token stays the row key.
class AddRespondentCodeToSurveysAndResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :respondent_code_enabled, :boolean, default: false, null: false
    # Creator's own wording for what to enter, e.g. "your nickname and the day of
    # the month you were born". Blank falls back to a generic prompt.
    add_column :surveys, :respondent_code_prompt, :string

    add_column :responses, :respondent_code_digest, :string
    add_index :responses, [ :survey_id, :respondent_code_digest ],
              name: "index_responses_on_survey_and_respondent_code"
  end
end
