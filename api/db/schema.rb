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

ActiveRecord::Schema[8.1].define(version: 2026_07_05_010000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "account_type", default: "other", null: false
    t.integer "balance_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "account_type", "label"], name: "index_accounts_on_household_account_type_label", unique: true
    t.index ["household_id", "account_type"], name: "index_accounts_on_household_id_and_account_type"
    t.index ["household_id"], name: "index_accounts_on_household_id"
    t.check_constraint "balance_cents >= 0", name: "accounts_balance_cents_non_negative"
  end

  create_table "budget_allocations", force: :cascade do |t|
    t.bigint "budget_category_id", null: false
    t.bigint "budget_period_id", null: false
    t.datetime "created_at", null: false
    t.integer "planned_amount_cents", default: 0, null: false
    t.string "source", default: "manual", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_category_id"], name: "index_budget_allocations_on_budget_category_id"
    t.index ["budget_period_id", "budget_category_id"], name: "idx_on_budget_period_id_budget_category_id_396e159b33", unique: true
    t.index ["budget_period_id"], name: "index_budget_allocations_on_budget_period_id"
    t.check_constraint "planned_amount_cents >= 0", name: "budget_allocations_amount_non_negative"
    t.check_constraint "source::text = ANY (ARRAY['manual'::character varying, 'setup'::character varying, 'imported'::character varying, 'mia_suggested'::character varying]::text[])", name: "budget_allocations_source_valid"
  end

  create_table "budget_categories", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "name", null: false
    t.integer "sort_order", default: 0, null: false
    t.string "stack_key", null: false
    t.datetime "updated_at", null: false
    t.index "household_id, lower((name)::text)", name: "index_budget_categories_on_household_lower_name", unique: true
    t.index ["household_id", "active", "sort_order"], name: "idx_on_household_id_active_sort_order_01ee1248fa"
    t.index ["household_id"], name: "index_budget_categories_on_household_id"
    t.check_constraint "char_length(name::text) <= 80", name: "budget_categories_name_length"
    t.check_constraint "stack_key::text = ANY (ARRAY['non_discretionary'::character varying, 'discretionary'::character varying, 'sinking_expected'::character varying, 'sinking_unexpected'::character varying]::text[])", name: "budget_categories_stack_key_valid"
  end

  create_table "budget_periods", force: :cascade do |t|
    t.bigint "budget_year_id", null: false
    t.datetime "created_at", null: false
    t.date "ends_on", null: false
    t.date "starts_on", null: false
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_year_id", "starts_on"], name: "index_budget_periods_on_budget_year_id_and_starts_on", unique: true
    t.index ["budget_year_id"], name: "index_budget_periods_on_budget_year_id"
    t.check_constraint "ends_on >= starts_on", name: "budget_periods_dates_ordered"
    t.check_constraint "status::text = ANY (ARRAY['open'::character varying, 'reviewing'::character varying, 'closed'::character varying]::text[])", name: "budget_periods_status_valid"
  end

  create_table "budget_years", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["household_id", "year"], name: "index_budget_years_on_household_id_and_year", unique: true
    t.index ["household_id"], name: "index_budget_years_on_household_id"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'active'::character varying, 'archived'::character varying]::text[])", name: "budget_years_status_valid"
    t.check_constraint "year >= 2000 AND year <= 2100", name: "budget_years_year_reasonable"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.jsonb "attachments", default: [], null: false
    t.bigint "chat_session_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "created_at"], name: "index_chat_messages_on_chat_session_id_and_created_at"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["role"], name: "index_chat_messages_on_role"
    t.check_constraint "char_length(content) <= 2000", name: "chat_messages_content_length"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.jsonb "active_topic", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.datetime "last_compacted_at"
    t.bigint "last_compacted_message_id"
    t.jsonb "open_topics", default: [], null: false
    t.text "rolling_summary"
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_id", "user_id"], name: "index_chat_sessions_on_household_id_and_user_id", unique: true
    t.index ["household_id"], name: "index_chat_sessions_on_household_id"
    t.index ["last_compacted_message_id"], name: "index_chat_sessions_on_last_compacted_message_id"
    t.index ["user_id"], name: "index_chat_sessions_on_user_id"
  end

  create_table "cohort_memberships", force: :cascade do |t|
    t.bigint "cohort_id", null: false
    t.datetime "created_at", null: false
    t.string "role", default: "participant", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["cohort_id", "user_id"], name: "index_cohort_memberships_on_cohort_id_and_user_id", unique: true
    t.index ["cohort_id"], name: "index_cohort_memberships_on_cohort_id"
    t.index ["user_id", "role"], name: "index_cohort_memberships_on_user_id_and_role"
    t.index ["user_id"], name: "index_cohort_memberships_on_user_id"
    t.check_constraint "role::text = ANY (ARRAY['participant'::character varying, 'coach'::character varying, 'admin'::character varying]::text[])", name: "cohort_memberships_role_valid"
  end

  create_table "cohorts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.date "ends_on"
    t.string "name", null: false
    t.text "notes"
    t.date "starts_on"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index "lower((name)::text)", name: "index_cohorts_on_lower_name", unique: true
    t.index ["created_by_user_id"], name: "index_cohorts_on_created_by_user_id"
    t.index ["status"], name: "index_cohorts_on_status"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'enrolling'::character varying, 'active'::character varying, 'completed'::character varying, 'archived'::character varying]::text[])", name: "cohorts_status_valid"
  end

  create_table "debts", force: :cascade do |t|
    t.integer "balance_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "debt_type", default: "other", null: false
    t.bigint "household_id", null: false
    t.decimal "interest_rate_percent", precision: 6, scale: 2
    t.string "label", null: false
    t.integer "minimum_payment_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "debt_type", "label"], name: "index_debts_on_household_debt_type_label", unique: true
    t.index ["household_id", "debt_type"], name: "index_debts_on_household_id_and_debt_type"
    t.index ["household_id"], name: "index_debts_on_household_id"
    t.check_constraint "balance_cents >= 0", name: "debts_balance_cents_non_negative"
    t.check_constraint "minimum_payment_cents >= 0", name: "debts_minimum_payment_cents_non_negative"
  end

  create_table "expense_items", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "amount_cents", default: 0, null: false
    t.string "cadence", default: "monthly", null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.string "stack_key", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "active"], name: "index_expense_items_on_household_id_and_active"
    t.index ["household_id", "stack_key", "label"], name: "index_expense_items_on_household_stack_key_label", unique: true
    t.index ["household_id", "stack_key"], name: "index_expense_items_on_household_id_and_stack_key"
    t.index ["household_id"], name: "index_expense_items_on_household_id"
    t.check_constraint "amount_cents >= 0", name: "expense_items_amount_cents_non_negative"
  end

  create_table "financial_document_import_attempts", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "financial_document_import_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "model", null: false
    t.string "prompt_version", null: false
    t.string "provider", null: false
    t.string "schema_version", null: false
    t.datetime "started_at", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["financial_document_import_id", "created_at"], name: "index_financial_doc_attempts_on_import_and_created"
    t.index ["financial_document_import_id"], name: "index_financial_doc_attempts_on_import_id"
    t.index ["status"], name: "index_financial_document_import_attempts_on_status"
    t.check_constraint "status::text = 'processing'::text OR completed_at IS NOT NULL", name: "financial_document_import_attempts_completed_at_required_when_t"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying, 'succeeded'::character varying, 'failed'::character varying]::text[])", name: "financial_document_import_attempts_status_valid"
  end

  create_table "financial_document_import_items", force: :cascade do |t|
    t.string "account_type"
    t.integer "amount_cents"
    t.datetime "applied_at"
    t.bigint "applied_by_user_id"
    t.bigint "applied_record_id"
    t.string "applied_record_type"
    t.integer "balance_cents"
    t.string "cadence"
    t.string "confidence"
    t.datetime "created_at", null: false
    t.string "debt_type"
    t.text "evidence"
    t.bigint "financial_document_import_id", null: false
    t.boolean "ignored", default: false, null: false
    t.string "label", null: false
    t.jsonb "metadata", default: {}, null: false
    t.integer "payment_cents"
    t.boolean "selected", default: true, null: false
    t.string "source_type"
    t.string "stack_key"
    t.string "target_type", null: false
    t.datetime "updated_at", null: false
    t.index ["applied_by_user_id"], name: "index_financial_document_import_items_on_applied_by_user_id"
    t.index ["applied_record_type", "applied_record_id"], name: "index_financial_doc_items_on_applied_record"
    t.index ["financial_document_import_id", "target_type"], name: "index_financial_doc_items_on_import_and_target"
    t.index ["financial_document_import_id"], name: "index_financial_doc_items_on_import_id"
    t.index ["ignored"], name: "index_financial_document_import_items_on_ignored"
    t.index ["selected"], name: "index_financial_document_import_items_on_selected"
    t.check_constraint "amount_cents IS NULL OR amount_cents >= 0", name: "financial_doc_items_amount_cents_non_negative"
    t.check_constraint "balance_cents IS NULL OR balance_cents >= 0", name: "financial_doc_items_balance_cents_non_negative"
    t.check_constraint "confidence IS NULL OR (confidence::text = ANY (ARRAY['high'::character varying, 'medium'::character varying, 'low'::character varying]::text[]))", name: "financial_document_import_items_confidence_valid"
    t.check_constraint "payment_cents IS NULL OR payment_cents >= 0", name: "financial_doc_items_payment_cents_non_negative"
    t.check_constraint "target_type::text = ANY (ARRAY['income_source'::character varying, 'expense_item'::character varying, 'account'::character varying, 'debt'::character varying, 'goal'::character varying, 'profile_note'::character varying]::text[])", name: "financial_document_import_items_target_type_valid"
  end

  create_table "financial_document_imports", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_user_id"
    t.bigint "byte_size", default: 0, null: false
    t.string "checksum_sha256"
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.date "document_date"
    t.string "document_kind", null: false
    t.text "extracted_summary"
    t.text "extraction_error"
    t.string "filename", null: false
    t.bigint "household_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.date "period_end_on"
    t.date "period_start_on"
    t.datetime "processed_at"
    t.string "s3_key"
    t.datetime "source_deleted_at"
    t.bigint "source_deleted_by_user_id"
    t.string "status", default: "uploaded", null: false
    t.datetime "updated_at", null: false
    t.bigint "uploaded_by_user_id", null: false
    t.index ["applied_by_user_id"], name: "index_financial_document_imports_on_applied_by_user_id"
    t.index ["household_id", "created_at"], name: "idx_on_household_id_created_at_ff25a98304"
    t.index ["household_id", "document_kind"], name: "idx_on_household_id_document_kind_5f848ae7ff"
    t.index ["household_id", "status"], name: "index_financial_document_imports_on_household_id_and_status"
    t.index ["household_id"], name: "index_financial_document_imports_on_household_id"
    t.index ["s3_key"], name: "index_financial_document_imports_on_s3_key"
    t.index ["source_deleted_by_user_id"], name: "index_financial_document_imports_on_source_deleted_by_user_id"
    t.index ["uploaded_by_user_id"], name: "index_financial_document_imports_on_uploaded_by_user_id"
    t.check_constraint "byte_size >= 0", name: "financial_document_imports_byte_size_non_negative"
    t.check_constraint "document_kind::text = ANY (ARRAY['spreadsheet'::character varying, 'statement'::character varying, 'pay_stub'::character varying, 'receipt'::character varying, 'other'::character varying]::text[])", name: "financial_document_imports_document_kind_valid"
    t.check_constraint "status::text = ANY (ARRAY['uploaded'::character varying, 'processing'::character varying, 'needs_review'::character varying, 'applied'::character varying, 'partially_applied'::character varying, 'failed'::character varying, 'source_deleted'::character varying]::text[])", name: "financial_document_imports_status_valid"
  end

  create_table "goals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "current_amount_cents", default: 0, null: false
    t.string "goal_type", default: "other", null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.integer "priority", default: 0, null: false
    t.integer "target_amount_cents", default: 0, null: false
    t.decimal "target_months", precision: 6, scale: 2
    t.datetime "updated_at", null: false
    t.index ["household_id", "goal_type"], name: "index_goals_on_household_id_and_goal_type"
    t.index ["household_id", "priority"], name: "index_goals_on_household_id_and_priority"
    t.index ["household_id"], name: "index_goals_on_household_id"
    t.index ["household_id"], name: "index_goals_on_one_runway_per_household", unique: true, where: "((goal_type)::text = 'runway'::text)"
    t.index ["household_id"], name: "index_goals_on_one_transition_per_household", unique: true, where: "((goal_type)::text = 'transition'::text)"
    t.check_constraint "current_amount_cents >= 0", name: "goals_current_amount_cents_non_negative"
    t.check_constraint "target_amount_cents >= 0", name: "goals_target_amount_cents_non_negative"
  end

  create_table "household_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "role", default: "owner", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_id", "user_id"], name: "index_household_memberships_on_household_id_and_user_id", unique: true
    t.index ["household_id"], name: "index_household_memberships_on_household_id"
    t.index ["role"], name: "index_household_memberships_on_role"
    t.index ["user_id"], name: "index_household_memberships_on_one_owner_per_user", unique: true, where: "((role)::text = 'owner'::text)"
    t.index ["user_id"], name: "index_household_memberships_on_user_id"
  end

  create_table "household_profiles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "household_stage"
    t.integer "money_stress_level"
    t.text "notes"
    t.text "primary_decision"
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_household_profiles_on_household_id", unique: true
  end

  create_table "household_transactions", force: :cascade do |t|
    t.bigint "budget_period_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "household_id", null: false
    t.string "merchant", null: false
    t.jsonb "metadata", default: {}, null: false
    t.date "occurred_on", null: false
    t.bigint "source_import_id"
    t.string "source_type", default: "manual_chat", null: false
    t.string "status", default: "confirmed", null: false
    t.integer "total_amount_cents", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_period_id", "status"], name: "index_household_transactions_on_budget_period_status"
    t.index ["budget_period_id"], name: "index_household_transactions_on_budget_period_id"
    t.index ["household_id", "occurred_on"], name: "index_household_transactions_on_household_id_and_occurred_on"
    t.index ["household_id", "status"], name: "index_household_transactions_on_household_id_and_status"
    t.index ["household_id"], name: "index_household_transactions_on_household_id"
    t.index ["source_import_id"], name: "index_household_transactions_on_source_import_id"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_chat'::character varying, 'manual_ui'::character varying, 'receipt'::character varying, 'screenshot'::character varying, 'statement'::character varying, 'import'::character varying]::text[])", name: "household_transactions_source_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['confirmed'::character varying, 'reconciled'::character varying, 'ignored'::character varying]::text[])", name: "household_transactions_status_valid"
    t.check_constraint "total_amount_cents > 0", name: "household_transactions_amount_positive"
  end

  create_table "households", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.string "location"
    t.string "name", null: false
    t.text "primary_goal"
    t.string "stage"
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_households_on_created_by_user_id"
  end

  create_table "income_sources", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "amount_cents", default: 0, null: false
    t.string "cadence", default: "monthly", null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.string "source_type", default: "other", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "active"], name: "index_income_sources_on_household_id_and_active"
    t.index ["household_id", "source_type", "label"], name: "index_income_sources_on_household_source_type_label", unique: true
    t.index ["household_id", "source_type"], name: "index_income_sources_on_household_id_and_source_type"
    t.index ["household_id"], name: "index_income_sources_on_household_id"
    t.check_constraint "amount_cents >= 0", name: "income_sources_amount_cents_non_negative"
  end

  create_table "invitation_email_attempts", force: :cascade do |t|
    t.datetime "attempted_at", null: false
    t.datetime "created_at", null: false
    t.text "error"
    t.string "provider", default: "resend", null: false
    t.string "provider_message_id"
    t.datetime "sent_at"
    t.bigint "sent_by_user_id"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["sent_by_user_id"], name: "index_invitation_email_attempts_on_sent_by_user_id"
    t.index ["status"], name: "index_invitation_email_attempts_on_status"
    t.index ["user_id", "attempted_at"], name: "index_invitation_email_attempts_on_user_id_and_attempted_at"
    t.index ["user_id"], name: "index_invitation_email_attempts_on_user_id"
    t.check_constraint "status::text <> 'sent'::text OR sent_at IS NOT NULL", name: "invitation_email_attempts_sent_at_required_when_sent"
    t.check_constraint "status::text = ANY (ARRAY['not_sent'::character varying, 'skipped'::character varying, 'sent'::character varying, 'failed'::character varying]::text[])", name: "invitation_email_attempts_status_valid"
  end

  create_table "merchant_category_rules", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "budget_category_id", null: false
    t.decimal "confidence", precision: 5, scale: 2, default: "0.8", null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.datetime "last_confirmed_at"
    t.string "merchant_pattern", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "source", default: "user_confirmed", null: false
    t.integer "times_confirmed", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["budget_category_id"], name: "index_merchant_category_rules_on_budget_category_id"
    t.index ["household_id", "active", "merchant_pattern"], name: "index_merchant_rules_on_household_active_pattern"
    t.index ["household_id", "merchant_pattern", "budget_category_id"], name: "index_merchant_rules_on_household_pattern_category", unique: true
    t.index ["household_id"], name: "index_merchant_category_rules_on_household_id"
    t.check_constraint "char_length(merchant_pattern::text) <= 120", name: "merchant_category_rules_pattern_length"
    t.check_constraint "confidence >= 0::numeric AND confidence <= 1::numeric", name: "merchant_category_rules_confidence_unit_interval"
    t.check_constraint "source::text = ANY (ARRAY['user_confirmed'::character varying, 'system_inferred'::character varying, 'coach_confirmed'::character varying]::text[])", name: "merchant_category_rules_source_valid"
    t.check_constraint "times_confirmed >= 0", name: "merchant_category_rules_times_confirmed_non_negative"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
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

  create_table "transaction_draft_matches", force: :cascade do |t|
    t.decimal "confidence", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.bigint "household_transaction_id", null: false
    t.string "match_reason"
    t.jsonb "metadata", default: {}, null: false
    t.string "status", default: "proposed", null: false
    t.bigint "transaction_draft_id", null: false
    t.datetime "updated_at", null: false
    t.index ["household_transaction_id", "status"], name: "index_draft_matches_on_transaction_and_status"
    t.index ["household_transaction_id"], name: "index_transaction_draft_matches_on_household_transaction_id"
    t.index ["transaction_draft_id", "household_transaction_id"], name: "index_draft_matches_on_draft_and_transaction", unique: true
    t.index ["transaction_draft_id"], name: "index_transaction_draft_matches_on_transaction_draft_id"
    t.check_constraint "status::text = ANY (ARRAY['proposed'::character varying, 'accepted'::character varying, 'rejected'::character varying]::text[])", name: "transaction_draft_matches_status_valid"
  end

  create_table "transaction_draft_splits", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.bigint "budget_category_id"
    t.string "category_name"
    t.decimal "confidence", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "notes"
    t.string "stack_key"
    t.bigint "transaction_draft_id", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_category_id"], name: "index_transaction_draft_splits_on_budget_category_id"
    t.index ["transaction_draft_id", "budget_category_id"], name: "index_draft_splits_on_draft_and_category"
    t.index ["transaction_draft_id"], name: "index_transaction_draft_splits_on_transaction_draft_id"
    t.check_constraint "amount_cents > 0", name: "transaction_draft_splits_amount_positive"
    t.check_constraint "stack_key IS NULL OR (stack_key::text = ANY (ARRAY['non_discretionary'::character varying, 'discretionary'::character varying, 'sinking_expected'::character varying, 'sinking_unexpected'::character varying]::text[]))", name: "transaction_draft_splits_stack_key_valid"
  end

  create_table "transaction_drafts", force: :cascade do |t|
    t.bigint "budget_category_id"
    t.decimal "confidence", precision: 5, scale: 2
    t.bigint "confirmed_transaction_id"
    t.datetime "created_at", null: false
    t.jsonb "draft_payload", default: {}, null: false
    t.bigint "financial_document_import_id"
    t.bigint "household_id", null: false
    t.bigint "matched_transaction_id"
    t.string "merchant", null: false
    t.date "occurred_on", null: false
    t.text "raw_input"
    t.string "source_type", default: "manual_chat", null: false
    t.string "status", default: "pending", null: false
    t.integer "total_amount_cents", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_category_id"], name: "index_transaction_drafts_on_budget_category_id"
    t.index ["confirmed_transaction_id"], name: "index_transaction_drafts_on_confirmed_transaction_id"
    t.index ["financial_document_import_id", "status"], name: "index_transaction_drafts_on_import_and_status"
    t.index ["financial_document_import_id"], name: "index_transaction_drafts_on_financial_document_import_id"
    t.index ["household_id", "status", "created_at"], name: "idx_on_household_id_status_created_at_cf0ad72279"
    t.index ["household_id"], name: "index_transaction_drafts_on_household_id"
    t.index ["matched_transaction_id"], name: "index_transaction_drafts_on_matched_transaction_id"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_chat'::character varying, 'manual_ui'::character varying, 'receipt'::character varying, 'screenshot'::character varying, 'statement'::character varying, 'import'::character varying]::text[])", name: "transaction_drafts_source_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'confirmed'::character varying, 'corrected'::character varying, 'ignored'::character varying, 'matched'::character varying]::text[])", name: "transaction_drafts_status_valid"
    t.check_constraint "total_amount_cents > 0", name: "transaction_drafts_amount_positive"
  end

  create_table "transaction_splits", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.bigint "budget_category_id", null: false
    t.datetime "created_at", null: false
    t.bigint "household_transaction_id", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.index ["budget_category_id"], name: "index_transaction_splits_on_budget_category_id"
    t.index ["household_transaction_id", "budget_category_id"], name: "index_transaction_splits_on_transaction_and_category"
    t.index ["household_transaction_id"], name: "index_transaction_splits_on_household_transaction_id"
    t.check_constraint "amount_cents > 0", name: "transaction_splits_amount_positive"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "accepted_at"
    t.string "clerk_id", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "first_name"
    t.text "invitation_email_error"
    t.string "invitation_email_provider_id"
    t.string "invitation_email_status", default: "not_sent", null: false
    t.string "invitation_status", default: "accepted", null: false
    t.datetime "invited_at"
    t.bigint "invited_by_user_id"
    t.datetime "last_invite_email_attempted_at"
    t.datetime "last_invite_email_sent_at"
    t.bigint "last_invite_email_sent_by_user_id"
    t.string "last_name"
    t.datetime "last_sign_in_at"
    t.string "role", default: "participant", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.index ["clerk_id"], name: "index_users_on_clerk_id", unique: true
    t.index ["invitation_email_status"], name: "index_users_on_invitation_email_status"
    t.index ["invitation_status"], name: "index_users_on_invitation_status"
    t.index ["invited_by_user_id"], name: "index_users_on_invited_by_user_id"
    t.index ["last_invite_email_sent_by_user_id"], name: "index_users_on_last_invite_email_sent_by_user_id"
    t.index ["role"], name: "index_users_on_role"
    t.check_constraint "invitation_email_status::text = ANY (ARRAY['not_sent'::character varying, 'skipped'::character varying, 'sent'::character varying, 'failed'::character varying]::text[])", name: "users_invitation_email_status_valid"
  end

  add_foreign_key "accounts", "households"
  add_foreign_key "budget_allocations", "budget_categories"
  add_foreign_key "budget_allocations", "budget_periods"
  add_foreign_key "budget_categories", "households"
  add_foreign_key "budget_periods", "budget_years"
  add_foreign_key "budget_years", "households"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_sessions", "households"
  add_foreign_key "chat_sessions", "users"
  add_foreign_key "cohort_memberships", "cohorts"
  add_foreign_key "cohort_memberships", "users"
  add_foreign_key "cohorts", "users", column: "created_by_user_id"
  add_foreign_key "debts", "households"
  add_foreign_key "expense_items", "households"
  add_foreign_key "financial_document_import_attempts", "financial_document_imports"
  add_foreign_key "financial_document_import_items", "financial_document_imports"
  add_foreign_key "financial_document_import_items", "users", column: "applied_by_user_id"
  add_foreign_key "financial_document_imports", "households"
  add_foreign_key "financial_document_imports", "users", column: "applied_by_user_id"
  add_foreign_key "financial_document_imports", "users", column: "source_deleted_by_user_id"
  add_foreign_key "financial_document_imports", "users", column: "uploaded_by_user_id"
  add_foreign_key "goals", "households"
  add_foreign_key "household_memberships", "households"
  add_foreign_key "household_memberships", "users"
  add_foreign_key "household_profiles", "households"
  add_foreign_key "household_transactions", "budget_periods"
  add_foreign_key "household_transactions", "financial_document_imports", column: "source_import_id"
  add_foreign_key "household_transactions", "households"
  add_foreign_key "households", "users", column: "created_by_user_id"
  add_foreign_key "income_sources", "households"
  add_foreign_key "invitation_email_attempts", "users"
  add_foreign_key "invitation_email_attempts", "users", column: "sent_by_user_id"
  add_foreign_key "merchant_category_rules", "budget_categories"
  add_foreign_key "merchant_category_rules", "households"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "transaction_draft_matches", "household_transactions"
  add_foreign_key "transaction_draft_matches", "transaction_drafts"
  add_foreign_key "transaction_draft_splits", "budget_categories"
  add_foreign_key "transaction_draft_splits", "transaction_drafts"
  add_foreign_key "transaction_drafts", "budget_categories"
  add_foreign_key "transaction_drafts", "financial_document_imports"
  add_foreign_key "transaction_drafts", "household_transactions", column: "confirmed_transaction_id"
  add_foreign_key "transaction_drafts", "household_transactions", column: "matched_transaction_id"
  add_foreign_key "transaction_drafts", "households"
  add_foreign_key "transaction_splits", "budget_categories"
  add_foreign_key "transaction_splits", "household_transactions"
  add_foreign_key "users", "users", column: "invited_by_user_id"
  add_foreign_key "users", "users", column: "last_invite_email_sent_by_user_id"
end
