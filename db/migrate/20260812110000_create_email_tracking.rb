# The per-recipient layer of a Comms send.
#
# - email_campaign_recipients: one row per address a campaign will reach,
#   snapshotted at flip-to-sending. `token` (random, unique) is the ONLY
#   identity public endpoints accept — sequential ids never appear in mail.
#   Emails are stored pre-normalized; [campaign, email] unique absorbs
#   snapshot races.
# - email_campaign_links: the click-tracking table. Destination URLs are
#   stored server-side at freeze time by the campaign author and looked up
#   by id scoped to the recipient's campaign — the redirect endpoint never
#   accepts a URL from the request, which is what keeps it a closed
#   redirect, not an open one.
# - email_events: append-only engagement log.
class CreateEmailTracking < ActiveRecord::Migration[8.1]
  def change
    create_table :email_campaign_recipients do |t|
      t.integer :email_campaign_id, null: false
      t.integer :user_id
      t.integer :email_list_contact_id
      t.string  :email, null: false
      t.string  :name
      t.string  :token, null: false
      t.string  :status, null: false, default: "queued"
      t.string  :error
      t.integer :subject_variant, null: false, default: 0
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :first_opened_at
      t.datetime :last_opened_at
      t.integer :open_count, null: false, default: 0
      t.datetime :first_clicked_at
      t.datetime :last_clicked_at
      t.integer :click_count, null: false, default: 0
      t.datetime :unsubscribed_at
      t.datetime :complained_at
      t.timestamps

      t.index [ :email_campaign_id, :email ], unique: true
      t.index [ :email_campaign_id, :status ]
      t.index :token, unique: true
      t.check_constraint "status IN ('queued','sending','sent','delivered','simulated','bounced','failed','skipped')",
                         name: "chk_email_campaign_recipients_status"
    end

    create_table :email_campaign_links do |t|
      t.integer :email_campaign_id, null: false
      t.text    :url, null: false
      t.datetime :created_at, null: false

      t.index :email_campaign_id
    end

    create_table :email_events do |t|
      t.integer :email_campaign_id
      t.integer :email_campaign_recipient_id
      t.string  :kind, null: false
      t.text    :url
      t.json    :meta
      t.datetime :occurred_at, null: false

      t.index [ :email_campaign_id, :kind ]
      t.index :occurred_at
      t.check_constraint "kind IN ('queued','sent','delivered','open','click','bounce','complaint','unsubscribe','failed','simulated','skipped')",
                         name: "chk_email_events_kind"
    end
  end
end
