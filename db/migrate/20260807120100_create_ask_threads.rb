# Ask Verto conversations, persisted.
#
# The per-Verto results chat keeps its messages in the browser and loses them on
# reload, which is fine for a sidebar you dip into while reading a results page.
# Ask Verto is the thing being sold: an answer a funder will quote in a report has
# to still be there tomorrow, with the same citations resolving to the same rows.
#
# Citations live on the message rather than in a join table because they are a
# snapshot of what was cited at the time. If a Verto is later withdrawn, the old
# answer must still say what it said and be readable as history — while no NEW
# answer can cite it. Storing the numbered list inline keeps those two facts
# separate; a join to corpus_questions would quietly rewrite history instead.
class CreateAskThreads < ActiveRecord::Migration[8.1]
  def change
    create_table :ask_threads do |t|
      t.references :organisation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :title
      # The corpus filters this conversation was asked under (theme, country,
      # year). Part of the answer's meaning: the same question over a different
      # scope is a different finding.
      t.json   :scope, null: false, default: {}

      t.timestamps
    end

    add_index :ask_threads, [ :organisation_id, :updated_at ]

    create_table :ask_messages do |t|
      t.references :ask_thread, null: false, foreign_key: true
      t.string :role, null: false
      t.text   :text, null: false, default: ""
      # [{ "n" => 1, "corpus_question_id" => 412, "verto" => "...", ... }]
      t.json   :citations, null: false, default: []

      t.timestamps
    end

    add_index :ask_messages, [ :ask_thread_id, :created_at ]

    add_check_constraint :ask_messages,
      "role IN ('user', 'assistant')",
      name: "chk_ask_messages_role"
  end
end
