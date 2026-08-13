# The weekly newsletter generator's idempotency key.
#
# Campaigns had no dedupe column: a recurring task that double-fires, a deploy
# that replays it, or a hand-run of the job would each mint another draft for
# the same week. This is the campaign-side equivalent of
# email_automation_runs.idempotency_key — one edition per week, enforced by the
# database rather than by the job remembering.
#
# Nullable and unique: every hand-authored campaign leaves it NULL, and both
# SQLite and Postgres allow repeated NULLs in a unique index.
class AddNewsletterWeekToEmailCampaigns < ActiveRecord::Migration[8.1]
  def change
    add_column :email_campaigns, :newsletter_week, :date
    add_index :email_campaigns, :newsletter_week, unique: true
  end
end
