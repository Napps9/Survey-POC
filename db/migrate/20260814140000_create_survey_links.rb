# Share links: named, individually-addressed /play/ URLs for one Verto.
#
# The Verto already had exactly one public address (publish_token, plus an
# optional vanity slug) and one set of respondent-facing switches. That makes
# "send this to two audiences on different terms" impossible: turning results
# comparison on for the cohort you want to show the aggregate to also turns it
# on for the control group who must not see it.
#
# A share link is that address made plural. Each carries its own slug in the
# same /play/:token namespace (see Survey.play_key_taken? — a slug here can
# never shadow a publish_token, another Verto's slug or a partner share token)
# and its own three-state overrides: nil means "whatever the Verto says",
# true/false pins it for everyone arriving through this link.
class CreateSurveyLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :survey_links do |t|
      t.references :survey, null: false, foreign_key: true
      t.string  :name, null: false
      t.string  :slug, null: false
      # Deliberately nullable: nil = inherit the Verto's own setting, so a link
      # created today keeps following the Verto unless someone pins it.
      t.boolean :show_results_comparison
      t.boolean :share_enabled
      t.boolean :regions_enabled
      # Switch one audience off without touching the others, and without
      # deleting the link (which would free its slug for reuse elsewhere).
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :survey_links, :slug, unique: true
    add_index :survey_links, [ :survey_id, :created_at ]

    # Attribution: which link a respondent arrived through, so the share modal
    # can say what each audience actually returned. Nullable — every response
    # collected before this existed, and everyone arriving on the Verto's own
    # link, has none. Mirrors responses.survey_share_id.
    add_reference :responses, :survey_link, null: true, foreign_key: true
  end
end
