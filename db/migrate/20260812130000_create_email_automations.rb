# Event-triggered email automations (Temple's engine, VertoNow's triggers).
#
# email_automations holds the config AND the compiled artifact — automations
# compile on save (no freeze step: what an enabled automation sends is
# always its latest saved content, which is the product's promise here,
# unlike campaigns' freeze-at-approval).
#
# email_automation_runs is the ledger AND the queue: one row per
# (automation, subject, anchor) with a UNIQUE idempotency_key, which is what
# makes the hourly enqueue sweep safe to run twice — the second insert of
# the same key is a no-op on both SQLite and Postgres via
# insert_all(unique_by:). send_days is json (a list of ISO weekday ints),
# NOT a Postgres array, so dev SQLite and prod Postgres read it alike.
class CreateEmailAutomations < ActiveRecord::Migration[8.1]
  def change
    create_table :email_automations do |t|
      t.string  :name, null: false, default: "Untitled automation"
      t.boolean :enabled, null: false, default: false
      t.string  :trigger_type, null: false, default: "user_signed_up"
      t.integer :delay_minutes, null: false, default: 0
      t.json    :params
      t.json    :conditions
      t.string  :subject, null: false, default: ""
      t.string  :preheader, null: false, default: ""
      t.string  :from_name
      t.string  :reply_to
      t.json    :design
      t.text    :compiled_html
      t.text    :compiled_text
      t.integer :send_hour
      t.json    :send_days
      t.integer :created_by_id
      t.timestamps

      t.index :enabled
      t.check_constraint "trigger_type IN ('user_signed_up','user_inactive','first_verto_published','first_response_received')",
                         name: "chk_email_automations_trigger"
      t.check_constraint "delay_minutes >= 0", name: "chk_email_automations_delay"
      t.check_constraint "send_hour IS NULL OR (send_hour >= 0 AND send_hour <= 23)",
                         name: "chk_email_automations_hour"
    end

    create_table :email_automation_runs do |t|
      t.integer :email_automation_id, null: false
      t.integer :user_id
      t.string  :email, null: false
      t.string  :name
      t.string  :token, null: false
      t.string  :status, null: false, default: "queued"
      t.string  :error
      t.string  :idempotency_key, null: false
      t.datetime :scheduled_at
      t.datetime :sent_at
      t.timestamps

      t.index :idempotency_key, unique: true
      t.index :token, unique: true
      t.index [ :status, :scheduled_at ]
      t.index :email_automation_id
      t.check_constraint "status IN ('queued','sending','sent','failed','skipped','suppressed','simulated')",
                         name: "chk_email_automation_runs_status"
    end

    add_column :email_events, :email_automation_run_id, :integer
    add_index :email_events, :email_automation_run_id
  end
end
