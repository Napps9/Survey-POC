# The Comms suite's campaign row (see CommsAccess for who ever sees it).
# The full column set lands up front — scheduling, A/B variants and the
# freeze-at-approval snapshot arrive in later milestones but their columns
# are part of one coherent design (ported from Temple's email_campaigns):
#
# - design/audience/scheduled_snapshot/subject_variants are json documents;
#   they are never queried in SQL (WHERE/ORDER/DISTINCT), which is what
#   keeps SQLite dev and Postgres prod agreeing.
# - compiled_html/compiled_text + scheduled_snapshot freeze what was
#   approved at send/schedule time; the live row stays editable and the
#   dispatcher reads only the frozen copy.
# - status transitions are model-method-only; the editor's autosave can
#   touch content columns and nothing else.
class CreateEmailCampaigns < ActiveRecord::Migration[8.1]
  def change
    create_table :email_campaigns do |t|
      t.string  :title, null: false, default: "Untitled campaign"
      t.string  :subject, null: false, default: ""
      t.string  :preheader, null: false, default: ""
      t.string  :from_name
      t.string  :reply_to
      t.string  :status, null: false, default: "draft"
      t.json    :design
      t.json    :audience
      t.json    :subject_variants
      t.text    :compiled_html
      t.text    :compiled_text
      t.json    :scheduled_snapshot
      t.datetime :scheduled_for
      t.datetime :sent_at
      t.integer :recipient_count, null: false, default: 0
      t.integer :created_by_id
      t.timestamps

      t.index :status
      t.index :scheduled_for
      t.index :created_at
      t.index :created_by_id
      t.check_constraint "status IN ('draft','scheduled','sending','sent','failed','cancelled')",
                         name: "chk_email_campaigns_status"
    end
  end
end
