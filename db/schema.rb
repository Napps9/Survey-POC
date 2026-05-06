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

ActiveRecord::Schema[8.1].define(version: 2026_05_06_000002) do
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

  create_table "surveys", force: :cascade do |t|
    t.string "audience_age"
    t.json "cards"
    t.datetime "created_at", null: false
    t.text "description"
    t.text "key_insight"
    t.string "publish_token"
    t.datetime "published_at"
    t.string "theme"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["publish_token"], name: "index_surveys_on_publish_token", unique: true
  end

  add_foreign_key "responses", "surveys"
end
