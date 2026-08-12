# One platform-wide "do not email" ledger for Comms. Blanket-only for v1 —
# VertoNow has no member-facing topic-preferences surface, so per-topic
# unsubscribe would ship UI nobody asked for. Topics later are an additive
# migration (a scope column here + topic_id on campaigns); nothing in this
# shape blocks that.
class CreateEmailSuppressions < ActiveRecord::Migration[8.1]
  def change
    create_table :email_suppressions do |t|
      # Pre-normalized; the audience resolver subtracts these by plain string
      # equality, so the count shown before Send is the number actually mailed.
      t.string  :email, null: false
      t.string  :reason, null: false
      t.integer :user_id
      t.integer :source_campaign_id
      t.timestamps

      t.index :email, unique: true
      t.check_constraint "reason IN ('unsubscribe','hard_bounce','complaint','manual')",
                         name: "chk_email_suppressions_reason"
    end
  end
end
