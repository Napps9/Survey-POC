# Publishing used to be one-way: nothing ever cleared publish_token, so a live
# Verto stayed live forever. This records the take-down instead of clearing the
# token, so re-publishing restores the SAME /play link — QR codes and anything
# already printed keep working.
class AddUnpublishedAtToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :unpublished_at, :datetime
  end
end
