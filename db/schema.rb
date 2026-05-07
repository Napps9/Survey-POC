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

ActiveRecord::Schema[8.1].define(version: 2026_05_07_070616) do
  create_table "invites", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "expires_at", null: false
    t.integer "invited_by_id", null: false
    t.integer "organisation_id", null: false
    t.string "role", default: "member", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_invites_on_invited_by_id"
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
    t.datetime "updated_at", null: false
    t.index ["session_token"], name: "index_responses_on_session_token", unique: true
    t.index ["survey_id"], name: "index_responses_on_survey_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "surveys", force: :cascade do |t|
    t.string "audience_age"
    t.json "cards"
    t.datetime "created_at", null: false
    t.text "description"
    t.text "key_insight"
    t.integer "organisation_id", null: false
    t.string "publish_token"
    t.datetime "published_at"
    t.text "results_summary"
    t.integer "results_summary_response_count"
    t.string "theme"
    t.string "title"
    t.datetime "updated_at", null: false
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

  add_foreign_key "invites", "organisations"
  add_foreign_key "invites", "users", column: "invited_by_id"
  add_foreign_key "memberships", "organisations"
  add_foreign_key "memberships", "users"
  add_foreign_key "responses", "surveys"
  add_foreign_key "sessions", "users"
  add_foreign_key "surveys", "organisations"
end
