# A shareable invitation to review one Verto's wording — the whole point of
# the Language check screen, which is that the people who can tell you whether
# your Spanish reads well are usually not people who have a Playverto account.
#
# The token IS the authorisation, exactly like results_share_token and a play
# link, so the same posture follows it everywhere: noindex on the response,
# Disallow in robots.txt, and a pause that survives the URL (active: false)
# distinct from a revoke that destroys it.
#
# Separate table rather than one more token column on `surveys` (which is how
# results sharing is done) because a review link is not one-per-Verto: a
# creator hands the French line to a French speaker and the Spanish line to a
# Spanish speaker, and wants to know afterwards which of them approved what.
# `locales` is that scoping — empty means every language the Verto has.
class CreateLanguageCheckLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :language_check_links do |t|
      t.references :survey, null: false, foreign_key: true
      t.string  :token, null: false
      # The creator's own label for whoever is holding it ("Marta — Spanish").
      # Shown back to the reviewer so a forwarded link says who it was for.
      t.string  :name
      # Which of the Verto's languages this link may see. [] = all of them.
      t.json    :locales,  null: false, default: []
      # Off makes the link a read-and-comment pass: approvals and notes still
      # land, the wording itself is untouchable. On (the default) is the
      # feature as asked for — a reviewer fixes the line there and then.
      t.boolean :can_edit, null: false, default: true
      t.boolean :active,   null: false, default: true
      t.references :created_by_user, foreign_key: { to_table: :users }
      t.datetime :last_seen_at
      t.timestamps
    end

    add_index :language_check_links, :token, unique: true
  end
end
