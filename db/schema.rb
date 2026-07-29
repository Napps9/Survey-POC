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

ActiveRecord::Schema[8.1].define(version: 2026_07_29_120000) do
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

  create_table "blazer_audits", force: :cascade do |t|
    t.datetime "created_at"
    t.string "data_source"
    t.integer "query_id"
    t.text "statement"
    t.integer "user_id"
    t.index ["query_id"], name: "index_blazer_audits_on_query_id"
    t.index ["user_id"], name: "index_blazer_audits_on_user_id"
  end

  create_table "blazer_checks", force: :cascade do |t|
    t.string "check_type"
    t.datetime "created_at", null: false
    t.integer "creator_id"
    t.text "emails"
    t.datetime "last_run_at"
    t.text "message"
    t.integer "query_id"
    t.string "schedule"
    t.text "slack_channels"
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_checks_on_creator_id"
    t.index ["query_id"], name: "index_blazer_checks_on_query_id"
  end

  create_table "blazer_dashboard_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "dashboard_id"
    t.integer "position"
    t.integer "query_id"
    t.datetime "updated_at", null: false
    t.index ["dashboard_id"], name: "index_blazer_dashboard_queries_on_dashboard_id"
    t.index ["query_id"], name: "index_blazer_dashboard_queries_on_query_id"
  end

  create_table "blazer_dashboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creator_id"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_dashboards_on_creator_id"
  end

  create_table "blazer_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creator_id"
    t.string "data_source"
    t.text "description"
    t.string "name"
    t.text "statement"
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_queries_on_creator_id"
  end

  create_table "common_question_sets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_locale", default: "en", null: false
    t.datetime "deleted_at"
    t.text "key_insight"
    t.string "name", null: false
    t.integer "organisation_id", null: false
    t.string "theme"
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_common_question_sets_on_deleted_at"
    t.index ["organisation_id"], name: "index_common_question_sets_on_organisation_id"
  end

  create_table "common_questions", force: :cascade do |t|
    t.boolean "allow_other", default: false, null: false
    t.string "card_type", null: false
    t.integer "common_question_set_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.json "options"
    t.integer "position", null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["common_question_set_id", "position"], name: "index_common_questions_on_common_question_set_id_and_position"
    t.index ["common_question_set_id"], name: "index_common_questions_on_common_question_set_id"
  end

  create_table "funder_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "funder_id", null: false
    t.integer "organisation_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["funder_id", "organisation_id"], name: "index_funder_memberships_on_funder_id_and_organisation_id", unique: true
    t.index ["funder_id"], name: "index_funder_memberships_on_funder_id"
    t.index ["organisation_id"], name: "index_funder_memberships_on_organisation_id"
  end

  create_table "funders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "organisation_id", null: false
    t.integer "seat_count", default: 0, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id", "name"], name: "index_funders_on_organisation_id_and_name", unique: true
    t.index ["organisation_id"], name: "index_funders_on_organisation_id"
  end

  create_table "identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["provider", "uid"], name: "index_identities_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "invites", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email_address"
    t.datetime "expires_at", null: false
    t.integer "funder_id"
    t.integer "invited_by_id", null: false
    t.string "kind", default: "member", null: false
    t.integer "organisation_id", null: false
    t.integer "partnership_id"
    t.string "role", default: "member", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["funder_id"], name: "index_invites_on_funder_id"
    t.index ["invited_by_id"], name: "index_invites_on_invited_by_id"
    t.index ["kind"], name: "index_invites_on_kind"
    t.index ["organisation_id"], name: "index_invites_on_organisation_id"
    t.index ["partnership_id"], name: "index_invites_on_partnership_id"
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
    t.boolean "funder_enabled", default: false, null: false
    t.boolean "internal", default: false, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organisations_on_slug", unique: true
  end

  create_table "partnership_common_question_sets", force: :cascade do |t|
    t.integer "common_question_set_id", null: false
    t.datetime "created_at", null: false
    t.integer "partnership_id", null: false
    t.datetime "updated_at", null: false
    t.index ["partnership_id", "common_question_set_id"], name: "idx_partnership_cq_sets_unique", unique: true
    t.index ["partnership_id"], name: "index_partnership_common_question_sets_on_partnership_id"
  end

  create_table "partnership_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organisation_id", null: false
    t.integer "partnership_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_partnership_memberships_on_organisation_id"
    t.index ["partnership_id", "organisation_id"], name: "idx_on_partnership_id_organisation_id_292249422a", unique: true
    t.index ["partnership_id"], name: "index_partnership_memberships_on_partnership_id"
  end

  create_table "partnership_vertos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "partnership_id", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["partnership_id", "survey_id"], name: "index_partnership_vertos_on_partnership_id_and_survey_id", unique: true
    t.index ["partnership_id"], name: "index_partnership_vertos_on_partnership_id"
    t.index ["survey_id"], name: "index_partnership_vertos_on_survey_id"
  end

  create_table "partnerships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "organisation_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id", "name"], name: "index_partnerships_on_organisation_id_and_name", unique: true
    t.index ["organisation_id"], name: "index_partnerships_on_organisation_id"
  end

  create_table "portfolio_common_question_sets", force: :cascade do |t|
    t.integer "common_question_set_id", null: false
    t.datetime "created_at", null: false
    t.integer "portfolio_id", null: false
    t.datetime "updated_at", null: false
    t.index ["common_question_set_id"], name: "index_portfolio_common_question_sets_on_common_question_set_id"
    t.index ["portfolio_id", "common_question_set_id"], name: "idx_portfolio_cq_sets_unique", unique: true
    t.index ["portfolio_id"], name: "index_portfolio_common_question_sets_on_portfolio_id"
  end

  create_table "portfolio_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "funder_membership_id", null: false
    t.integer "portfolio_id", null: false
    t.datetime "updated_at", null: false
    t.index ["funder_membership_id"], name: "index_portfolio_memberships_on_funder_membership_id"
    t.index ["portfolio_id", "funder_membership_id"], name: "idx_portfolio_memberships_unique", unique: true
    t.index ["portfolio_id"], name: "index_portfolio_memberships_on_portfolio_id"
  end

  create_table "portfolios", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.integer "funder_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_portfolios_on_deleted_at"
    t.index ["funder_id", "name"], name: "index_portfolios_on_funder_id_and_name", unique: true
    t.index ["funder_id"], name: "index_portfolios_on_funder_id"
  end

  create_table "report_renders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "status", default: "pending", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["status", "created_at"], name: "index_report_renders_on_status_and_created_at"
    t.index ["survey_id"], name: "index_report_renders_on_survey_id"
    t.index ["user_id"], name: "index_report_renders_on_user_id"
  end

  create_table "responses", force: :cascade do |t|
    t.boolean "answered", default: false, null: false
    t.json "answers", default: {}, null: false
    t.datetime "completed_at"
    t.datetime "consent_agreed_at"
    t.datetime "consent_declined_at"
    t.text "consent_text_snapshot"
    t.datetime "created_at", null: false
    t.integer "demographic_birth_year"
    t.string "demographic_gender"
    t.string "device_kind"
    t.string "locale"
    t.integer "quiz_max"
    t.string "region_country"
    t.string "region_label"
    t.integer "score"
    t.string "session_token", null: false
    t.datetime "started_at"
    t.string "status", default: "completed", null: false
    t.integer "survey_id", null: false
    t.integer "survey_share_id"
    t.json "token_totals", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["session_token"], name: "index_responses_on_session_token", unique: true
    t.index ["survey_id", "answered", "status"], name: "index_responses_on_survey_answered_status"
    t.index ["survey_id", "demographic_birth_year"], name: "index_responses_on_survey_id_and_demographic_birth_year"
    t.index ["survey_id", "demographic_gender"], name: "index_responses_on_survey_id_and_demographic_gender"
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

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", limit: 1024, null: false
    t.integer "channel_hash", limit: 8, null: false
    t.datetime "created_at", null: false
    t.binary "payload", limit: 536870912, null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "survey_shares", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "partner_organisation_id", null: false
    t.integer "partnership_verto_id", null: false
    t.string "share_token", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["partner_organisation_id"], name: "index_survey_shares_on_partner_organisation_id"
    t.index ["partnership_verto_id", "partner_organisation_id"], name: "index_survey_shares_on_pv_and_partner", unique: true
    t.index ["partnership_verto_id"], name: "index_survey_shares_on_partnership_verto_id"
    t.index ["share_token"], name: "index_survey_shares_on_share_token", unique: true
    t.index ["survey_id"], name: "index_survey_shares_on_survey_id"
  end

  create_table "surveys", force: :cascade do |t|
    t.string "audience_age"
    t.text "background_image"
    t.json "brand_palette"
    t.json "cards"
    t.string "compare_note"
    t.text "consent_image"
    t.string "consent_image_credit"
    t.string "consent_image_credit_url"
    t.text "consent_text"
    t.datetime "created_at", null: false
    t.string "default_locale", default: "en", null: false
    t.datetime "deleted_at"
    t.text "description"
    t.json "end_screens", default: [], null: false
    t.json "flows", default: [], null: false
    t.string "forward_url"
    t.text "key_insight"
    t.json "locales"
    t.boolean "logic", default: false, null: false
    t.integer "organisation_id", null: false
    t.string "publish_token"
    t.datetime "published_at"
    t.boolean "quiz", default: false, null: false
    t.string "render_mode", default: "cards", null: false
    t.text "results_report"
    t.text "results_report_brief"
    t.datetime "results_report_edited_at"
    t.integer "results_report_response_count"
    t.text "results_summary"
    t.integer "results_summary_response_count"
    t.boolean "show_results_comparison", default: false, null: false
    t.string "slug"
    t.text "thankyou_body"
    t.string "thankyou_title"
    t.string "theme"
    t.string "title"
    t.json "token_types", default: [], null: false
    t.boolean "tokenisation_enabled", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_surveys_on_deleted_at"
    t.index ["organisation_id"], name: "index_surveys_on_organisation_id"
    t.index ["publish_token"], name: "index_surveys_on_publish_token", unique: true
    t.index ["slug"], name: "index_surveys_on_slug", unique: true
  end

  create_table "translation_cache", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "source_hash", null: false
    t.string "source_locale", null: false
    t.string "target_locale", null: false
    t.json "translation", null: false
    t.datetime "updated_at", null: false
    t.index ["source_hash", "source_locale", "target_locale"], name: "idx_translation_cache_lookup", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.text "google_access_token"
    t.datetime "google_connected_at"
    t.string "google_email"
    t.text "google_refresh_token"
    t.datetime "google_token_expires_at"
    t.string "name", default: "", null: false
    t.string "password_digest", null: false
    t.boolean "password_pending", default: false, null: false
    t.string "preferred_locale"
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "verto_builds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "kind", default: "generate", null: false
    t.integer "organisation_id", null: false
    t.json "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.integer "survey_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["organisation_id", "created_at"], name: "index_verto_builds_on_organisation_id_and_created_at"
    t.index ["organisation_id"], name: "index_verto_builds_on_organisation_id"
    t.index ["status"], name: "index_verto_builds_on_status"
    t.index ["survey_id"], name: "index_verto_builds_on_survey_id"
    t.index ["user_id"], name: "index_verto_builds_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "common_question_sets", "organisations"
  add_foreign_key "common_questions", "common_question_sets"
  add_foreign_key "funder_memberships", "funders"
  add_foreign_key "funder_memberships", "organisations"
  add_foreign_key "funders", "organisations"
  add_foreign_key "invites", "funders"
  add_foreign_key "invites", "organisations"
  add_foreign_key "invites", "partnerships"
  add_foreign_key "invites", "users", column: "invited_by_id"
  add_foreign_key "memberships", "organisations"
  add_foreign_key "memberships", "users"
  add_foreign_key "partnership_memberships", "organisations"
  add_foreign_key "partnership_memberships", "partnerships"
  add_foreign_key "partnership_vertos", "partnerships"
  add_foreign_key "partnership_vertos", "surveys"
  add_foreign_key "partnerships", "organisations"
  add_foreign_key "portfolio_common_question_sets", "common_question_sets"
  add_foreign_key "portfolio_common_question_sets", "portfolios"
  add_foreign_key "portfolio_memberships", "funder_memberships"
  add_foreign_key "portfolio_memberships", "portfolios"
  add_foreign_key "portfolios", "funders"
  add_foreign_key "report_renders", "surveys"
  add_foreign_key "report_renders", "users"
  add_foreign_key "responses", "survey_shares"
  add_foreign_key "responses", "surveys"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "survey_shares", "organisations", column: "partner_organisation_id"
  add_foreign_key "survey_shares", "partnership_vertos"
  add_foreign_key "survey_shares", "surveys"
  add_foreign_key "surveys", "organisations"
  add_foreign_key "verto_builds", "organisations"
  add_foreign_key "verto_builds", "surveys"
  add_foreign_key "verto_builds", "users"
end
