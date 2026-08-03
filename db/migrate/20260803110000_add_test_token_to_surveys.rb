# Test Mode: a shareable link (/test/:token) that plays the full Verto —
# drafts included — without sign-in, records nothing, and keeps working while
# the creator edits. A separate token from publish_token on purpose: the
# publish token is load-bearing for printed QR codes and must never be cycled
# by test-link regeneration.
class AddTestTokenToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :test_token, :string
    add_index :surveys, :test_token, unique: true
  end
end
