# One row per (Verto, card, language) line on the Language check screen — the
# review state of ONE card's text in ONE of the Verto's languages.
#
# Keyed by `cid` rather than the card's position, for the reason every other
# per-card record in this app is: the positional index is a moving target (a
# reorder re-points it), the cid is the card's identity (Survey.ensure_cids!).
#
# `content_digest` is what makes an approval mean something. It is a hash of
# the exact words that were approved, so the moment anybody edits that line the
# stored approval no longer matches what is in the deck and the line reads
# "Approved, then edited" rather than showing a green tick over text nobody has
# read. Without it an approval would be a permanent badge on mutable content,
# which is worse than no badge at all — a reviewer signing off Spanish would be
# vouching for whatever Spanish the card ends up holding.
#
# `edit_revision` carries the Verto's translations_revision at the moment a
# reviewer's edit landed. SurveysController#update replaces `cards` wholesale
# from the editor's DOM, so an editor tab opened BEFORE a reviewer edit would
# otherwise write its stale copy of that language back over the fresh one on
# the next autosave. The number lets the server carry forward exactly the
# (cid, locale) pairs the client provably had not seen — the same shape as
# Survey.keep_setup_media, for the same class of two-writers bug.
class CreateLanguageChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :language_checks do |t|
      t.references :survey, null: false, foreign_key: true
      t.string :cid,    null: false
      t.string :locale, null: false
      # pending           — nobody has ruled on this line yet
      # approved          — reads correctly in this language
      # changes_requested — a reviewer has flagged it; see the notes
      t.string   :status, null: false, default: "pending"
      t.string   :content_digest
      # The digest of the PRIMARY language's wording for this card at the
      # moment the line was decided. A translation review is a judgement about
      # fidelity to a source, so an approval of the Spanish has to lapse when
      # the English underneath it changes — not only when the Spanish does.
      # Null on a primary-language row, which has no source above it.
      t.string   :source_digest
      t.string   :reviewed_by_name
      t.references :reviewed_by_user,   foreign_key: { to_table: :users }
      t.references :language_check_link, foreign_key: true
      t.datetime :reviewed_at
      t.datetime :edited_at
      t.string   :edited_by_name
      t.integer  :edit_revision, null: false, default: 0
      t.timestamps
    end

    add_index :language_checks, [ :survey_id, :cid, :locale ], unique: true,
              name: "index_language_checks_on_survey_card_locale"
    add_index :language_checks, [ :survey_id, :edit_revision ],
              name: "index_language_checks_on_survey_edit_revision"

    add_check_constraint :language_checks,
      "status IN ('pending', 'approved', 'changes_requested')",
      name: "chk_language_checks_status"
  end
end
