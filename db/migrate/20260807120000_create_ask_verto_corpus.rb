# The Ask Verto corpus — the data a cross-Verto chatbot is allowed to answer from.
#
# Three tables, and the split matters:
#
#   corpus_entries    one row per Verto that has ever been OFFERED. Holds both
#                     consent gates (the creator's opt-in and VertoNow's review)
#                     plus the audit trail a citation has to be able to show.
#   corpus_questions  the retrieval index. One row per citable question, with its
#                     distribution already aggregated. Ask Verto reads THESE, never
#                     `responses` — so a bug in the chat layer cannot reach a
#                     respondent's row.
#   corpus_quotes     verbatim open-text, redacted, one row each. Separate from the
#                     question so a single quote can be pulled without re-indexing,
#                     and so "how many quotes does this Verto contribute" is a count
#                     a reviewer can act on.
#
# Nothing is enrolled by existing: a Verto with no corpus_entries row is simply not
# in the corpus, which is the correct default for every Verto that already exists.
class CreateAskVertoCorpus < ActiveRecord::Migration[8.1]
  def change
    create_table :corpus_entries do |t|
      t.references :survey, null: false, foreign_key: true, index: { unique: true }
      # Denormalised from the survey so the whole corpus can be scoped, counted and
      # revoked per account without joining surveys on every read.
      t.references :organisation, null: false, foreign_key: true

      # ── Gate 1: the creator ──────────────────────────────────────────────
      # NULL means never offered. withdrawn_at beats opted_in_at, so a withdrawal
      # is recorded rather than erasing the fact that consent was once given.
      t.datetime :opted_in_at
      t.references :opted_in_by, foreign_key: { to_table: :users }
      t.datetime :withdrawn_at

      # ── Gate 2: VertoNow ─────────────────────────────────────────────────
      t.string   :review_status, null: false, default: "pending"
      t.datetime :reviewed_at
      # The reviewer's email rather than a user_id: staff are identified by the
      # BLAZER_STAFF_EMAILS allowlist (app/lib/blazer_access.rb), not by a role
      # column, and the allowlist can name someone who has no account here.
      t.string   :reviewed_by_email
      # Shown to the creator VERBATIM. "Fewer than 30 completed responses" is
      # actionable; "not accepted" is not.
      t.text     :review_note

      # ── Index state ──────────────────────────────────────────────────────
      t.datetime :indexed_at
      t.integer  :response_count, null: false, default: 0
      t.json     :check_results, null: false, default: {}

      t.timestamps
    end

    add_index :corpus_entries, :review_status
    # The queue's own query: opted in, not withdrawn, awaiting a decision.
    add_index :corpus_entries, [ :review_status, :opted_in_at ]

    add_check_constraint :corpus_entries,
      "review_status IN ('pending', 'approved', 'declined')",
      name: "chk_corpus_entries_review_status"

    create_table :corpus_questions do |t|
      t.references :corpus_entry, null: false, foreign_key: true

      # The card's cid within the deck, so a re-index can match a question to its
      # previous row even after the deck is reordered.
      t.string  :cid
      t.integer :position
      t.string  :card_type, null: false
      t.text    :question_text, null: false
      t.json    :options, null: false, default: []
      t.string  :theme

      # Already aggregated: {label => count} for the choice types, {"avg" =>, ...}
      # for rating. Computed once at index time by CorpusIndexer.
      t.json    :distribution, null: false, default: {}
      t.integer :response_count, null: false, default: 0
      # Gender / age-band / country splits. Any cell under the minimum sample is
      # dropped before it is written, not filtered on read — suppressed data that
      # was never stored cannot leak through a later query.
      t.json    :segments, null: false, default: {}

      t.timestamps
    end

    add_index :corpus_questions, [ :corpus_entry_id, :position ]
    add_index :corpus_questions, :card_type

    create_table :corpus_quotes do |t|
      t.references :corpus_question, null: false, foreign_key: true
      # Already redacted and length-capped by QuoteRedactor before it gets here.
      t.text    :body, null: false
      t.string  :theme
      # A reviewer (or a later pass of the identifiability check) can retire one
      # quote without touching the question it belongs to.
      t.boolean :approved, null: false, default: true

      t.timestamps
    end

    add_index :corpus_quotes, [ :corpus_question_id, :approved ]
  end
end
