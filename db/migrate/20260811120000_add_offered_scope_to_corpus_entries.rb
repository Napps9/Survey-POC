# Question-set granularity for the Ask Verto corpus: a creator can now offer a
# whole Verto or just some of its question sets (a common question set, or the
# Verto's own questions). `{}` means everything — every existing row keeps the
# meaning it was created with.
class AddOfferedScopeToCorpusEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :corpus_entries, :offered_scope, :json, default: {}, null: false
  end
end
