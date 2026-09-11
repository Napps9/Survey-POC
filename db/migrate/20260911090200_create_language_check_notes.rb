# A comment left on one (Verto, card, language) line. Free text, threadless —
# a line's notes are a short conversation about one question's wording, not a
# discussion forum, and the flat list is what the reviewer and the creator both
# read top to bottom.
#
# Keyed by cid + locale to match language_checks, and deliberately NOT a
# belongs_to on that row: a note can be the first thing that happens to a line
# (comment without ruling on it), and a creator clearing a review state should
# not silently delete what somebody wrote about it.
#
# `author_name` is a plain typed name, not an identity. A link holder has no
# account by construction — that is the feature — so attribution here is a
# courtesy label, and the controller keeps it bounded and screened rather than
# trusting it. Where a signed-in user leaves the note, author_user_id carries
# the real identity alongside it.
class CreateLanguageCheckNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :language_check_notes do |t|
      t.references :survey, null: false, foreign_key: true
      t.string :cid,    null: false
      t.string :locale, null: false
      t.text   :body,   null: false
      t.string :author_name
      t.references :author_user,         foreign_key: { to_table: :users }
      t.references :language_check_link, foreign_key: true
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :language_check_notes, [ :survey_id, :cid, :locale ],
              name: "index_language_check_notes_on_survey_card_locale"
  end
end
