class CreateHeldTexts < ActiveRecord::Migration[8.1]
  # A respondent's free-text answer, lifted out of responses.answers at write
  # time and parked here until something — the screen or a person — decides
  # it can be shown. See Moderation (app/lib/moderation.rb) for the design and
  # HeldText for the lifecycle.
  def change
    create_table :held_texts do |t|
      t.references :response,     null: false, foreign_key: true
      t.references :survey,       null: false, foreign_key: true
      t.references :organisation, null: false, foreign_key: true

      # Where in the answer the text came from: the card's index (the answers
      # key) and which slot — the open_ended "value" or an "Other" write-in.
      t.integer :card_index, null: false
      t.string  :slot,       null: false

      # The question as it read when the answer arrived, so a reviewer (and
      # the screen) see the text in context even after the deck is edited.
      t.string :question

      # The scrubbed text (Moderation::Scrub has already run), encrypted at
      # rest with Active Record Encryption. Nullable because the sweep blanks
      # it once a removed text's retention lapses — the row stays as the record
      # that a removal happened.
      t.text   :text
      t.string :text_digest, null: false
      # Which contact-detail patterns the scrub fired on this text, for the
      # reviewer's context and for a count of what the scrub is catching.
      t.json   :scrub_hits, null: false, default: {}

      t.string :status, null: false, default: "pending"

      # The screen's verdict, kept whatever the outcome so a person reviewing
      # sees what Claude thought and how sure it was.
      t.string   :category
      t.float    :certainty
      t.text     :verdict_note
      t.datetime :screened_at
      t.integer  :screen_attempts, null: false, default: 0
      t.string   :last_screen_error

      # The decision. `auto` when the screen made it; a person's email when a
      # person did.
      t.boolean  :auto, null: false, default: false
      t.datetime :decided_at
      t.string   :decided_by_email
      t.text     :decision_note
      # When the sweep may blank a removed text.
      t.datetime :purge_after

      t.timestamps
    end

    # The review queue (open items, oldest first, per account / per Verto),
    # the sweep's scans, and the per-response lookup the hold does on every
    # write.
    add_index :held_texts, [ :organisation_id, :status ]
    add_index :held_texts, [ :survey_id, :status ]
    add_index :held_texts, [ :status, :updated_at ]
    add_index :held_texts, [ :survey_id, :text_digest ]
    # One row per distinct text per slot per response: a replayed write (the
    # player resends the whole answers hash on every advance; the offline
    # queue replays bodies verbatim) finds its row instead of creating another.
    add_index :held_texts, [ :response_id, :card_index, :slot, :text_digest ],
              unique: true, name: "index_held_texts_on_response_slot_digest"

    add_check_constraint :held_texts,
      "status IN ('pending', 'screening', 'review', 'released', 'removed', 'safeguarding', 'superseded')",
      name: "chk_held_texts_status"
    add_check_constraint :held_texts,
      "slot IN ('value', 'other')",
      name: "chk_held_texts_slot"
  end
end
