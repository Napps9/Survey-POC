class CascadeImageReviewRequestForeignKeys < ActiveRecord::Migration[8.1]
  # The image appeal/review feature is gone from the app, but its table stays:
  # approved appeal images are ActiveStorage blobs that live CARDS point at
  # directly (the picker wrote the blob path onto the card rather than copying
  # the bytes), so dropping the table would purge images out of published
  # Vertos. The rows are dormant data now, kept until someone decides
  # deliberately what to do with them.
  #
  # What has to change is the foreign keys. Survey#image_review_requests
  # carried `dependent: :destroy`, and that — not the database — is what
  # cleared these rows ahead of the FK on a hard delete. With the model gone,
  # SurveysController#destroy_forever (and Organisation's cascade into its
  # surveys) would raise ActiveRecord::InvalidForeignKey on any Verto that ever
  # had an appeal filed against it. Cascading in the database keeps every
  # delete path working with no model to maintain.
  #
  # Deliberately NOT touching active_storage_attachments: those rows are
  # polymorphic with no FK, so a cascaded delete here orphans the attachment
  # rather than purging the blob — which is the outcome we want. The image
  # keeps resolving for any card still pointing at it. The cost is a storage
  # leak of orphaned rows, which is the cheaper half of the trade.
  def up
    change_fk :image_review_requests, :surveys,       :survey_id,       cascade: true
    change_fk :image_review_requests, :organisations, :organisation_id, cascade: true
    change_fk :image_review_requests, :users,         :user_id,         cascade: true
  end

  def down
    change_fk :image_review_requests, :surveys,       :survey_id,       cascade: false
    change_fk :image_review_requests, :organisations, :organisation_id, cascade: false
    change_fk :image_review_requests, :users,         :user_id,         cascade: false
  end

  private

  # Both engines are in play (SQLite in dev/test, Postgres in prod) and they
  # implement this differently — Postgres drops and re-adds the constraint,
  # SQLite rebuilds the table — so go through the adapter rather than raw SQL.
  def change_fk(table, to_table, column, cascade:)
    remove_foreign_key table, to_table, column: column
    add_foreign_key table, to_table, column: column, **(cascade ? { on_delete: :cascade } : {})
  end
end
