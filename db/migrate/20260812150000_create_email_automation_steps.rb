# Follow-up steps: a drip sequence hanging off one automation. Every step's
# delay_minutes counts from the TRIGGER ANCHOR, not the previous step
# (Temple's semantics) — deleting or reordering a step never re-times the
# others. A step's runs carry `:step:<id>` in their idempotency key, so
# adding a step later books the new follow-up for eligible subjects without
# ever re-sending the primary.
class CreateEmailAutomationSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :email_automation_steps do |t|
      t.integer :email_automation_id, null: false
      t.integer :position, null: false, default: 1
      t.integer :delay_minutes, null: false, default: 1440
      t.integer :send_hour
      t.json    :send_days
      t.string  :subject, null: false, default: ""
      t.string  :preheader, null: false, default: ""
      t.json    :design
      t.text    :compiled_html
      t.text    :compiled_text
      t.timestamps

      t.index :email_automation_id
      t.check_constraint "delay_minutes >= 0", name: "chk_email_automation_steps_delay"
      t.check_constraint "send_hour IS NULL OR (send_hour >= 0 AND send_hour <= 23)",
                         name: "chk_email_automation_steps_hour"
    end

    add_column :email_automation_runs, :email_automation_step_id, :integer
    add_index :email_automation_runs, :email_automation_step_id
  end
end
