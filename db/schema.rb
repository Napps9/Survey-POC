# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_20_000002) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "alliances", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organisation_id", null: false
    t.integer "partner_organisation_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id", "partner_organisation_id"], name: "index_alliances_on_org_and_partner", unique: true
    t.index ["organisation_id"], name: "index_alliances_on_organisation_id"
    t.index ["partner_organisation_id"], name: "index_alliances_on_partner_organisation_id"
  end

  create_table "invites", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email_address"
    t.datetime "expires_at", null: false
    t.integer "invited_by_id", null: false
    t.string "kind", default: "member", null: false
    t.integer "organisation_id", null: false
    t.string "role", default: "member", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_invites_on_invited_by_id"
    t.index ["kind"], name: "index_invites_on_kind"
    t.index ["organisation_id"], name: "index_invites_on_organisation_id"
    t.index ["token"], name: "index_invites_on_token", unique: true
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organisation_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["organisation_id"], name: "index_memberships_on_organisation_id"
    t.index ["user_id", "organisation_id"], name: "index_memberships_on_user_id_and_organisation_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "organisations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "default_brand_palette"
    t.string "kind", default: "creator", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organisations_on_slug", unique: true
  end

  create_table "responses", force: :cascade do |t|
    t.json "answers", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "session_token", null: false
    t.string "status", default: "completed", null: false
    t.integer "survey_id", null: false
    t.integer "survey_share_id"
    t.datetime "updated_at", null: false
    t.index ["session_token"], name: "index_responses_on_session_token", unique: true
    t.index ["survey_id"], name: "index_responses_on_survey_id"
    t.index ["survey_share_id"], name: "index_responses_on_survey_share_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "survey_shares", force: :cascade do |t|
    t.integer "alliance_id"
    t.datetime "created_at", null: false
    t.string "label"
    t.string "share_token", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["alliance_id"], name: "index_survey_shares_on_alliance_id"
    t.index ["share_token"], name: "index_survey_shares_on_share_token", unique: true
    t.index ["survey_id", "alliance_id"], name: "index_survey_shares_on_survey_id_and_alliance_id", unique: true, where: "alliance_id IS NOT NULL"
    t.index ["survey_id"], name: "index_survey_shares_on_survey_id"
  end

  create_table "surveys", force: :cascade do |t|
    t.string "audience_age"
    t.json "brand_palette"
    t.json "cards"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.text "description"
    t.text "key_insight"
    t.integer "organisation_id", null: false
    t.string "publish_token"
    t.datetime "published_at"
    t.text "results_summary"
    t.integer "results_summary_response_count"
    t.boolean "show_results_comparison", default: false, null: false
    t.string "theme"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_surveys_on_deleted_at"
    t.index ["organisation_id"], name: "index_surveys_on_organisation_id"
    t.index ["publish_token"], name: "index_surveys_on_publish_token", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "name", default: "", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "alliances", "organisations"
  add_foreign_key "alliances", "organisations", column: "partner_organisation_id"
  add_foreign_key "invites", "organisations"
  add_foreign_key "invites", "users", column: "invited_by_id"
  add_foreign_key "memberships", "organisations"
  add_foreign_key "memberships", "users"
  add_foreign_key "responses", "survey_shares"
  add_foreign_key "responses", "surveys"
  add_foreign_key "sessions", "users"
  add_foreign_key "survey_shares", "alliances"
  add_foreign_key "survey_shares", "surveys"
  add_foreign_key "surveys", "organisations"
end
