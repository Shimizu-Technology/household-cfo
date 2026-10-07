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

ActiveRecord::Schema[8.1].define(version: 2026_10_07_200006) do
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_debt_terms_valid(value jsonb)
     RETURNS boolean
     LANGUAGE plpgsql
     IMMUTABLE
    AS $function$
    DECLARE field text; rate jsonb; day date; allocated numeric := 0;
    BEGIN
      IF jsonb_typeof(value) IS DISTINCT FROM 'object' OR NOT value ?& ARRAY['label','as_of_on','balance_cents','minimum_payment_cents','apr_bps','due_on','promotional_apr_bps','promotional_expires_on','post_promo_apr_bps','rate_segments','status'] OR (SELECT count(*) FROM jsonb_object_keys(value)) <> 11 THEN RETURN false; END IF;
      IF jsonb_typeof(value->'label') IS DISTINCT FROM 'string' OR length(btrim(value->>'label'))=0 OR length(value->>'label')>120 OR jsonb_typeof(value->'status') IS DISTINCT FROM 'string' OR value->>'status' NOT IN ('active','paid_off','archived') THEN RETURN false; END IF;
      FOREACH field IN ARRAY ARRAY['balance_cents','minimum_payment_cents','apr_bps','promotional_apr_bps','post_promo_apr_bps'] LOOP
        IF value->field <> 'null'::jsonb THEN
          IF jsonb_typeof(value->field) <> 'number' OR (value->>field) !~ '^[0-9]+$' OR (value->>field)::numeric > (CASE WHEN field LIKE '%apr_bps' THEN 100000 ELSE 9223372036854775807 END) THEN RETURN false; END IF;
        END IF;
      END LOOP;
      IF value->>'status'='paid_off' AND value->'balance_cents' IS DISTINCT FROM '0'::jsonb THEN RETURN false; END IF;
      FOREACH field IN ARRAY ARRAY['as_of_on','due_on','promotional_expires_on'] LOOP
        IF value->field <> 'null'::jsonb THEN
          IF jsonb_typeof(value->field) <> 'string' OR value->>field !~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN false; END IF;
          day := (value->>field)::date;
        ELSIF field='as_of_on' THEN RETURN false;
        END IF;
      END LOOP;
      IF jsonb_typeof(value->'rate_segments') IS DISTINCT FROM 'array' OR jsonb_array_length(value->'rate_segments')>8 THEN RETURN false; END IF;
      FOR rate IN SELECT jsonb_array_elements(value->'rate_segments') LOOP
        IF jsonb_typeof(rate) IS DISTINCT FROM 'object' OR NOT rate ?& ARRAY['label','balance_cents','apr_bps','promotional_expires_on','post_promo_apr_bps'] OR (SELECT count(*) FROM jsonb_object_keys(rate))<>5 OR jsonb_typeof(rate->'label') IS DISTINCT FROM 'string' OR length(btrim(rate->>'label'))=0 OR length(rate->>'label')>120 THEN RETURN false; END IF;
        FOREACH field IN ARRAY ARRAY['balance_cents','apr_bps','post_promo_apr_bps'] LOOP
          IF rate->field <> 'null'::jsonb AND (jsonb_typeof(rate->field)<>'number' OR rate->>field !~ '^[0-9]+$' OR (rate->>field)::numeric > (CASE WHEN field LIKE '%apr_bps' THEN 100000 ELSE 9223372036854775807 END)) THEN RETURN false; END IF;
        END LOOP;
        IF rate->'promotional_expires_on' <> 'null'::jsonb THEN
          IF rate->>'promotional_expires_on' !~ '^\d{4}-\d{2}-\d{2}$' OR jsonb_typeof(rate->'promotional_expires_on')<>'string' THEN RETURN false; END IF;
          day := (rate->>'promotional_expires_on')::date;
        END IF;
        allocated := allocated + coalesce((rate->>'balance_cents')::numeric,0);
      END LOOP;
      RETURN value->'balance_cents'='null'::jsonb OR allocated <= (value->>'balance_cents')::numeric;
    EXCEPTION WHEN OTHERS THEN RETURN false;
    END; $function$
  SQL
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "account_type", default: "other", null: false
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.date "balance_as_of_on"
    t.bigint "balance_cents", default: 0, null: false
    t.boolean "balance_known", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.bigint "plaid_account_id"
    t.datetime "plaid_reconciled_at"
    t.jsonb "source_metadata", default: {}, null: false
    t.string "source_type", default: "manual_ui", null: false
    t.datetime "updated_at", null: false
    t.index "household_id, financial_generation, account_type, lower((label)::text)", name: "index_active_accounts_on_household_type_label", unique: true, where: "(active = true)"
    t.index ["household_id", "account_type"], name: "index_accounts_on_household_id_and_account_type"
    t.index ["household_id", "active"], name: "index_accounts_on_household_id_and_active"
    t.index ["household_id"], name: "index_accounts_on_household_id"
    t.index ["id", "household_id"], name: "accounts_source_review_household_identity", unique: true
    t.index ["plaid_account_id", "financial_generation"], name: "index_accounts_on_unique_plaid_account", unique: true, where: "(plaid_account_id IS NOT NULL)"
    t.check_constraint "(account_type::text = ANY (ARRAY['checking'::character varying, 'savings'::character varying]::text[])) OR balance_cents >= 0", name: "accounts_balance_signed_only_for_cash"
    t.check_constraint "active = true AND archived_at IS NULL OR active = false AND archived_at IS NOT NULL", name: "accounts_archive_state_valid"
    t.check_constraint "balance_known = true OR balance_cents = 0 AND balance_as_of_on IS NULL", name: "accounts_unknown_balance_zero_without_date"
    t.check_constraint "jsonb_typeof(source_metadata) = 'object'::text", name: "accounts_source_metadata_object"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_ui'::character varying, 'mia'::character varying, 'document_import'::character varying, 'setup'::character varying, 'plaid'::character varying]::text[])", name: "accounts_source_type_valid"
  end

  create_table "authentication_identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "issuer", null: false
    t.string "provider", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["provider", "issuer", "subject"], name: "index_auth_identities_on_external_identity", unique: true
    t.index ["user_id", "provider", "issuer"], name: "index_auth_identities_on_user_provider", unique: true
    t.index ["user_id"], name: "index_authentication_identities_on_user_id"
    t.check_constraint "provider::text = ANY (ARRAY['clerk'::character varying::text, 'workos'::character varying::text])", name: "authentication_identities_provider_check"
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
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.string "name", null: false
    t.integer "sort_order", default: 0, null: false
    t.string "stack_key", null: false
    t.datetime "updated_at", null: false
    t.index "household_id, financial_generation, lower((name)::text)", name: "index_budget_categories_on_household_lower_name", unique: true
    t.index ["household_id", "active", "sort_order"], name: "idx_on_household_id_active_sort_order_01ee1248fa"
    t.index ["household_id"], name: "index_budget_categories_on_household_id"
    t.index ["id", "household_id"], name: "budget_categories_source_review_household_identity", unique: true
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
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["household_id", "financial_generation", "year"], name: "index_budget_years_on_household_id_and_year", unique: true
    t.index ["household_id"], name: "index_budget_years_on_household_id"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'active'::character varying, 'archived'::character varying]::text[])", name: "budget_years_status_valid"
    t.check_constraint "year >= 2000 AND year <= 2100", name: "budget_years_year_reasonable"
  end

  create_table "challenge_privacy_events", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id", null: false
    t.jsonb "approved_values", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.bigint "participant_user_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "subject_id", null: false
    t.string "subject_type", null: false
    t.index ["actor_user_id"], name: "index_challenge_privacy_events_on_actor_user_id"
    t.index ["household_id"], name: "index_challenge_privacy_events_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_privacy_events_on_participant_user_id"
    t.index ["savings_enrollment_id"], name: "index_challenge_privacy_events_on_savings_enrollment_id"
  end

  create_table "challenge_privacy_grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.boolean "granted", default: false, null: false
    t.bigint "household_id", null: false
    t.string "kind", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "participant_user_id", null: false
    t.string "policy_version", null: false
    t.bigint "recipient_user_id"
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "selected_records", default: [], null: false
    t.datetime "updated_at", null: false
    t.index "savings_enrollment_id, kind, COALESCE(recipient_user_id, (0)::bigint)", name: "challenge_privacy_grant_identity", unique: true
    t.index ["household_id"], name: "index_challenge_privacy_grants_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_privacy_grants_on_participant_user_id"
    t.index ["recipient_user_id"], name: "index_challenge_privacy_grants_on_recipient_user_id"
    t.index ["savings_enrollment_id"], name: "index_challenge_privacy_grants_on_savings_enrollment_id"
    t.check_constraint "(kind::text = ANY (ARRAY['coach_summary'::character varying, 'selected_details'::character varying, 'sponsor_aggregate'::character varying]::text[])) AND (kind::text = 'sponsor_aggregate'::text AND recipient_user_id IS NULL OR kind::text <> 'sponsor_aggregate'::text AND recipient_user_id IS NOT NULL)", name: "challenge_privacy_grant_kind"
  end

  create_table "challenge_privacy_reads", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.bigint "participant_user_id", null: false
    t.string "purpose", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.bigint "savings_enrollment_id", null: false
    t.index ["actor_user_id"], name: "index_challenge_privacy_reads_on_actor_user_id"
    t.index ["household_id"], name: "index_challenge_privacy_reads_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_privacy_reads_on_participant_user_id"
    t.index ["savings_enrollment_id"], name: "index_challenge_privacy_reads_on_savings_enrollment_id"
  end

  create_table "challenge_reminder_events", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id", null: false
    t.jsonb "approved_values", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.bigint "participant_user_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "subject_id", null: false
    t.string "subject_type", null: false
    t.index ["actor_user_id"], name: "index_challenge_reminder_events_on_actor_user_id"
    t.index ["household_id"], name: "index_challenge_reminder_events_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_reminder_events_on_participant_user_id"
    t.index ["savings_enrollment_id"], name: "index_challenge_reminder_events_on_savings_enrollment_id"
  end

  create_table "challenge_reminder_preferences", force: :cascade do |t|
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", null: false
    t.bigint "household_id", null: false
    t.string "local_time", default: "18:00", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "participant_user_id", null: false
    t.string "policy_version", null: false
    t.string "quiet_end", default: "08:00", null: false
    t.string "quiet_start", default: "21:00", null: false
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_challenge_reminder_preferences_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_reminder_preferences_on_participant_user_id"
    t.index ["savings_enrollment_id", "channel"], name: "challenge_reminder_preference_identity", unique: true
    t.index ["savings_enrollment_id"], name: "index_challenge_reminder_preferences_on_savings_enrollment_id"
    t.check_constraint "channel::text = ANY (ARRAY['in_app'::character varying, 'email'::character varying]::text[])", name: "challenge_reminder_preferences_channel"
    t.check_constraint "local_time::text ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text AND quiet_start::text ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text AND quiet_end::text ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text", name: "challenge_reminder_clock"
  end

  create_table "challenge_reminders", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.bigint "challenge_reminder_preference_id", null: false
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "delivery_key", null: false
    t.boolean "delivery_uncertain", default: false, null: false
    t.datetime "dismissed_at"
    t.bigint "household_id", null: false
    t.datetime "lease_expires_at"
    t.string "lease_token"
    t.date "local_on", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "next_attempt_at", null: false
    t.bigint "participant_user_id", null: false
    t.boolean "provider_idempotent", default: false, null: false
    t.string "provider_namespace"
    t.string "reason_code", default: "scheduled", null: false
    t.bigint "savings_enrollment_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["challenge_reminder_preference_id"], name: "index_challenge_reminders_on_challenge_reminder_preference_id"
    t.index ["delivery_key"], name: "index_challenge_reminders_on_delivery_key", unique: true
    t.index ["household_id"], name: "index_challenge_reminders_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_reminders_on_participant_user_id"
    t.index ["savings_enrollment_id", "local_on", "channel"], name: "challenge_reminder_day_identity", unique: true
    t.index ["savings_enrollment_id"], name: "index_challenge_reminders_on_savings_enrollment_id"
    t.index ["status", "next_attempt_at"], name: "challenge_reminder_due"
    t.check_constraint "(status::text = ANY (ARRAY['pending'::character varying, 'leased'::character varying, 'delivered'::character varying, 'cancelled'::character varying, 'failed'::character varying, 'unknown'::character varying]::text[])) AND attempts >= 0 AND attempts <= 5", name: "challenge_reminder_state"
    t.check_constraint "channel::text = ANY (ARRAY['in_app'::character varying, 'email'::character varying]::text[])", name: "challenge_reminders_channel"
    t.check_constraint "status::text = 'leased'::text AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL OR status::text <> 'leased'::text AND lease_token IS NULL AND lease_expires_at IS NULL", name: "challenge_reminder_lease"
  end

  create_table "challenge_sponsor_exports", force: :cascade do |t|
    t.bigint "approved_by_user_id", null: false
    t.integer "checkpoint_day", null: false
    t.bigint "cohort_id", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.string "policy_version", null: false
    t.jsonb "private_provenance", default: {}, null: false
    t.jsonb "report", default: {}, null: false
    t.date "resolved_cutoff_on", null: false
    t.index ["approved_by_user_id"], name: "index_challenge_sponsor_exports_on_approved_by_user_id"
    t.index ["cohort_id", "checkpoint_day", "policy_version"], name: "challenge_sponsor_fixed_identity", unique: true
    t.index ["cohort_id"], name: "index_challenge_sponsor_exports_on_cohort_id"
    t.check_constraint "checkpoint_day = ANY (ARRAY[30, 60, 90])", name: "challenge_sponsor_day"
  end

  create_table "challenge_support_accesses", force: :cascade do |t|
    t.bigint "challenge_support_ticket_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "participant_user_id", null: false
    t.string "reason", limit: 500, null: false
    t.bigint "recipient_user_id", null: false
    t.datetime "revoked_at"
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "selected_records", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["challenge_support_ticket_id"], name: "idx_on_challenge_support_ticket_id_25cf13fca8"
    t.index ["household_id"], name: "index_challenge_support_accesses_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_support_accesses_on_participant_user_id"
    t.index ["recipient_user_id"], name: "index_challenge_support_accesses_on_recipient_user_id"
    t.index ["savings_enrollment_id"], name: "index_challenge_support_accesses_on_savings_enrollment_id"
  end

  create_table "challenge_support_tickets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "issue_kind", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "message", limit: 500, null: false
    t.bigint "participant_user_id", null: false
    t.bigint "recipient_user_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "selected_records", default: [], null: false
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_challenge_support_tickets_on_household_id"
    t.index ["participant_user_id"], name: "index_challenge_support_tickets_on_participant_user_id"
    t.index ["recipient_user_id"], name: "index_challenge_support_tickets_on_recipient_user_id"
    t.index ["savings_enrollment_id"], name: "index_challenge_support_tickets_on_savings_enrollment_id"
    t.check_constraint "status::text = ANY (ARRAY['open'::character varying, 'triaged'::character varying, 'resolved'::character varying]::text[])", name: "challenge_support_status"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.string "assistant_author"
    t.jsonb "attachments", default: [], null: false
    t.bigint "chat_session_id", null: false
    t.bigint "coach_persona_version_id"
    t.bigint "cohort_id"
    t.bigint "cohort_release_id"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.jsonb "financial_restart", default: {}, null: false
    t.jsonb "presentation", default: {}, null: false
    t.string "role", null: false
    t.jsonb "setup_help", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "created_at"], name: "index_chat_messages_on_chat_session_id_and_created_at"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["coach_persona_version_id"], name: "index_chat_messages_on_coach_persona_version_id"
    t.index ["cohort_id"], name: "index_chat_messages_on_cohort_id"
    t.index ["cohort_release_id", "cohort_id"], name: "idx_chat_messages_release_cohort"
    t.index ["cohort_release_id"], name: "index_chat_messages_on_cohort_release_id"
    t.index ["role"], name: "index_chat_messages_on_role"
    t.check_constraint "(assistant_author IS NULL OR role::text = 'assistant'::text) AND (coach_persona_version_id IS NULL OR role::text = 'assistant'::text AND assistant_author IS NOT NULL)", name: "chat_messages_persona_attribution_complete"
    t.check_constraint "(role::text = ANY (ARRAY['user'::character varying, 'assistant'::character varying]::text[])) AND char_length(content) <= 8000", name: "chat_messages_content_length_by_role"
    t.check_constraint "assistant_author IS NULL OR char_length(assistant_author::text) >= 1 AND char_length(assistant_author::text) <= 80", name: "chat_messages_assistant_author_length"
    t.check_constraint "cohort_release_id IS NULL OR cohort_id IS NOT NULL", name: "chat_messages_release_attribution_complete"
    t.check_constraint "jsonb_typeof(presentation) = 'object'::text", name: "chat_messages_presentation_object"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.jsonb "active_topic", default: {}, null: false
    t.bigint "cohort_id"
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.datetime "last_compacted_at"
    t.bigint "last_compacted_message_id"
    t.jsonb "open_topics", default: [], null: false
    t.text "rolling_summary"
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["cohort_id"], name: "index_chat_sessions_on_cohort_id"
    t.index ["household_id", "user_id", "cohort_id"], name: "index_chat_sessions_on_household_user_cohort", unique: true, where: "(cohort_id IS NOT NULL)"
    t.index ["household_id", "user_id"], name: "index_chat_sessions_on_household_id_and_user_id", unique: true, where: "(cohort_id IS NULL)"
    t.index ["household_id"], name: "index_chat_sessions_on_household_id"
    t.index ["last_compacted_message_id"], name: "index_chat_sessions_on_last_compacted_message_id"
    t.index ["user_id"], name: "index_chat_sessions_on_user_id"
  end

  create_table "coach_content_citations", force: :cascade do |t|
    t.bigint "chat_message_id", null: false
    t.bigint "coach_content_item_version_id", null: false
    t.bigint "coach_content_pack_version_id", null: false
    t.datetime "created_at", null: false
    t.integer "rank", null: false
    t.string "reason", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_message_id", "coach_content_item_version_id"], name: "idx_content_citations_message_item", unique: true
    t.index ["chat_message_id", "rank"], name: "idx_content_citations_message_rank", unique: true
    t.index ["chat_message_id"], name: "index_coach_content_citations_on_chat_message_id"
    t.index ["coach_content_item_version_id"], name: "index_coach_content_citations_on_coach_content_item_version_id"
    t.index ["coach_content_pack_version_id"], name: "index_coach_content_citations_on_coach_content_pack_version_id"
    t.check_constraint "rank > 0 AND rank <= 6", name: "coach_content_citations_rank_valid"
  end

  create_table "coach_content_item_draft_provenances", force: :cascade do |t|
    t.datetime "accepted_at", null: false
    t.bigint "accepted_by_user_id", null: false
    t.string "attempt_model", null: false
    t.string "attempt_prompt_version", null: false
    t.string "attempt_provider", null: false
    t.string "attempt_schema_version", null: false
    t.string "candidate_content_digest", null: false
    t.string "candidate_original_proposal_digest", null: false
    t.string "candidate_review_action", null: false
    t.integer "candidate_revision", null: false
    t.bigint "coach_content_item_id", null: false
    t.bigint "coach_content_source_attempt_id", null: false
    t.bigint "coach_content_source_candidate_id", null: false
    t.bigint "coach_content_source_id", null: false
    t.datetime "created_at", null: false
    t.string "evidence_excerpt_digest", null: false
    t.jsonb "evidence_locator", default: {}, null: false
    t.string "provenance_digest", null: false
    t.integer "provenance_digest_version", default: 1, null: false
    t.bigint "source_byte_size", null: false
    t.string "source_checksum_sha256", null: false
    t.string "source_content_type", null: false
    t.string "source_filename", null: false
    t.string "source_ingestion_method", default: "upload", null: false
    t.datetime "updated_at", null: false
    t.index ["accepted_by_user_id"], name: "idx_on_accepted_by_user_id_332eae8c27"
    t.index ["coach_content_item_id"], name: "idx_content_item_draft_provenance_item", unique: true
    t.index ["coach_content_source_attempt_id"], name: "idx_on_coach_content_source_attempt_id_117748e08c"
    t.index ["coach_content_source_candidate_id"], name: "idx_on_coach_content_source_candidate_id_c55f8aad4d"
    t.index ["coach_content_source_id"], name: "idx_on_coach_content_source_id_16084b7d2c"
    t.check_constraint "candidate_content_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_draft_provenances_candidate_digest_sha256"
    t.check_constraint "candidate_original_proposal_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_draft_provenances_original_digest_sha256"
    t.check_constraint "candidate_review_action::text = 'accepted'::text", name: "coach_content_item_draft_provenances_review_action_accepted"
    t.check_constraint "candidate_revision > 0", name: "coach_content_item_draft_provenances_candidate_revision_positiv"
    t.check_constraint "evidence_excerpt_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_draft_provenances_excerpt_digest_sha256"
    t.check_constraint "provenance_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_draft_provenances_provenance_digest_sha256"
    t.check_constraint "provenance_digest_version = ANY (ARRAY[1, 2])", name: "coach_content_item_draft_provenances_digest_version_valid"
    t.check_constraint "source_byte_size > 0", name: "coach_content_item_draft_provenances_source_size_positive"
    t.check_constraint "source_checksum_sha256::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_draft_provenances_source_checksum_sha256"
    t.check_constraint "source_ingestion_method::text = ANY (ARRAY['upload'::character varying, 'url_snapshot'::character varying]::text[])", name: "coach_content_item_draft_provenances_ingestion_method_valid"
  end

  create_table "coach_content_item_version_provenances", force: :cascade do |t|
    t.datetime "accepted_at", null: false
    t.bigint "accepted_by_user_id", null: false
    t.string "approved_content_digest", null: false
    t.string "attempt_model", null: false
    t.string "attempt_prompt_version", null: false
    t.string "attempt_provider", null: false
    t.string "attempt_schema_version", null: false
    t.string "candidate_content_digest", null: false
    t.string "candidate_original_proposal_digest", null: false
    t.string "candidate_review_action", null: false
    t.integer "candidate_revision", null: false
    t.bigint "coach_content_item_version_id", null: false
    t.bigint "coach_content_source_attempt_id", null: false
    t.bigint "coach_content_source_candidate_id", null: false
    t.bigint "coach_content_source_id", null: false
    t.datetime "created_at", null: false
    t.string "evidence_excerpt_digest", null: false
    t.jsonb "evidence_locator", default: {}, null: false
    t.string "provenance_digest", null: false
    t.integer "provenance_digest_version", default: 1, null: false
    t.bigint "source_byte_size", null: false
    t.string "source_checksum_sha256", null: false
    t.string "source_content_type", null: false
    t.string "source_filename", null: false
    t.string "source_ingestion_method", default: "upload", null: false
    t.datetime "updated_at", null: false
    t.index ["accepted_by_user_id"], name: "idx_on_accepted_by_user_id_34a5b728f1"
    t.index ["coach_content_item_version_id"], name: "idx_content_item_version_provenance_version", unique: true
    t.index ["coach_content_source_attempt_id"], name: "idx_on_coach_content_source_attempt_id_facf47babc"
    t.index ["coach_content_source_candidate_id"], name: "idx_on_coach_content_source_candidate_id_16f47a46cb"
    t.index ["coach_content_source_id"], name: "idx_on_coach_content_source_id_c7e8f32f58"
    t.check_constraint "approved_content_digest::text ~ '^[0-9a-f]{64}$'::text", name: "content_item_version_provenance_approved_digest_sha256"
    t.check_constraint "candidate_content_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_version_provenances_candidate_digest_sha256"
    t.check_constraint "candidate_original_proposal_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_version_provenances_original_digest_sha256"
    t.check_constraint "candidate_review_action::text = 'accepted'::text", name: "coach_content_item_version_provenances_review_action_accepted"
    t.check_constraint "candidate_revision > 0", name: "coach_content_item_version_provenances_candidate_revision_posit"
    t.check_constraint "evidence_excerpt_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_version_provenances_excerpt_digest_sha256"
    t.check_constraint "provenance_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_version_provenances_provenance_digest_sha256"
    t.check_constraint "provenance_digest_version = ANY (ARRAY[1, 2])", name: "coach_content_item_version_provenances_digest_version_valid"
    t.check_constraint "source_byte_size > 0", name: "coach_content_item_version_provenances_source_size_positive"
    t.check_constraint "source_checksum_sha256::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_version_provenances_source_checksum_sha256"
    t.check_constraint "source_ingestion_method::text = ANY (ARRAY['upload'::character varying, 'url_snapshot'::character varying]::text[])", name: "coach_content_item_version_provenances_ingestion_method_valid"
  end

  create_table "coach_content_item_versions", force: :cascade do |t|
    t.boolean "always_on", default: false, null: false
    t.bigint "approved_by_user_id", null: false
    t.bigint "coach_content_item_id", null: false
    t.text "content", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_coach_content_item_versions_on_approved_by_user_id"
    t.index ["coach_content_item_id", "version_number"], name: "idx_content_item_versions_number", unique: true
    t.index ["coach_content_item_id"], name: "index_coach_content_item_versions_on_coach_content_item_id"
    t.index ["content_digest"], name: "index_coach_content_item_versions_on_content_digest"
    t.check_constraint "content_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_item_versions_digest_sha256"
    t.check_constraint "octet_length(content) <= 12000", name: "coach_content_item_versions_content_bytes"
    t.check_constraint "version_number > 0", name: "coach_content_item_versions_number_positive"
  end

  create_table "coach_content_items", force: :cascade do |t|
    t.datetime "archived_at"
    t.bigint "coach_workspace_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "current_approved_version_id"
    t.boolean "draft_always_on", default: false, null: false
    t.text "draft_content", null: false
    t.integer "draft_revision", default: 1, null: false
    t.string "kind", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "scope", default: "coach", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index "coach_workspace_id, lower((title)::text)", name: "idx_coach_content_items_workspace_title", unique: true, where: "((scope)::text = 'coach'::text)"
    t.index "created_by_user_id, lower((title)::text)", name: "idx_platform_content_items_owner_title", unique: true, where: "((scope)::text = 'platform'::text)"
    t.index ["coach_workspace_id"], name: "index_coach_content_items_on_coach_workspace_id"
    t.index ["created_by_user_id"], name: "index_coach_content_items_on_created_by_user_id"
    t.index ["current_approved_version_id"], name: "idx_content_items_current_version"
    t.check_constraint "draft_revision > 0", name: "coach_content_items_revision_positive"
    t.check_constraint "kind::text = ANY (ARRAY['guidance'::character varying, 'script'::character varying, 'example'::character varying, 'phrase'::character varying, 'culture'::character varying, 'finance_reference'::character varying]::text[])", name: "coach_content_items_kind_valid"
    t.check_constraint "octet_length(draft_content) <= 12000", name: "coach_content_items_content_bytes"
    t.check_constraint "scope::text = 'platform'::text AND coach_workspace_id IS NULL OR scope::text = 'coach'::text AND coach_workspace_id IS NOT NULL", name: "coach_content_items_workspace_matches_scope"
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying, 'platform'::character varying]::text[])", name: "coach_content_items_scope_valid"
  end

  create_table "coach_content_pack_draft_entries", force: :cascade do |t|
    t.bigint "coach_content_item_version_id", null: false
    t.bigint "coach_content_pack_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_content_item_version_id"], name: "idx_on_coach_content_item_version_id_ac4465000a"
    t.index ["coach_content_pack_id", "coach_content_item_version_id"], name: "idx_pack_draft_entries_item_version", unique: true
    t.index ["coach_content_pack_id", "position"], name: "idx_pack_draft_entries_position", unique: true
    t.index ["coach_content_pack_id"], name: "idx_on_coach_content_pack_id_7a43074d6c"
    t.check_constraint "\"position\" >= 0", name: "coach_content_pack_draft_entries_position_nonnegative"
  end

  create_table "coach_content_pack_version_entries", force: :cascade do |t|
    t.bigint "coach_content_item_version_id", null: false
    t.bigint "coach_content_pack_version_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_content_item_version_id"], name: "idx_on_coach_content_item_version_id_3184aabf01"
    t.index ["coach_content_pack_version_id", "coach_content_item_version_id"], name: "idx_pack_version_entries_item_version", unique: true
    t.index ["coach_content_pack_version_id", "position"], name: "idx_pack_version_entries_position", unique: true
    t.index ["coach_content_pack_version_id"], name: "idx_on_coach_content_pack_version_id_266ad2ad2f"
    t.check_constraint "\"position\" >= 0", name: "coach_content_pack_version_entries_position_nonnegative"
  end

  create_table "coach_content_pack_versions", force: :cascade do |t|
    t.bigint "coach_content_pack_id", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "pack_kind", null: false
    t.bigint "published_by_user_id", null: false
    t.string "scope", null: false
    t.datetime "sealed_at"
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["coach_content_pack_id", "version_number"], name: "idx_content_pack_versions_number", unique: true
    t.index ["coach_content_pack_id"], name: "index_coach_content_pack_versions_on_coach_content_pack_id"
    t.index ["published_by_user_id"], name: "index_coach_content_pack_versions_on_published_by_user_id"
    t.check_constraint "content_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_pack_versions_digest_sha256"
    t.check_constraint "version_number > 0", name: "coach_content_pack_versions_number_positive"
  end

  create_table "coach_content_packs", force: :cascade do |t|
    t.datetime "archived_at"
    t.bigint "coach_workspace_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "current_published_version_id"
    t.text "description"
    t.integer "draft_revision", default: 1, null: false
    t.integer "lock_version", default: 0, null: false
    t.string "name", null: false
    t.string "pack_kind", null: false
    t.string "scope", default: "coach", null: false
    t.datetime "updated_at", null: false
    t.index "coach_workspace_id, lower((name)::text)", name: "idx_coach_content_packs_workspace_name", unique: true, where: "((scope)::text = 'coach'::text)"
    t.index "created_by_user_id, lower((name)::text)", name: "idx_platform_content_packs_owner_name", unique: true, where: "((scope)::text = 'platform'::text)"
    t.index ["coach_workspace_id"], name: "index_coach_content_packs_on_coach_workspace_id"
    t.index ["created_by_user_id"], name: "index_coach_content_packs_on_created_by_user_id"
    t.index ["current_published_version_id"], name: "idx_content_packs_current_version"
    t.check_constraint "draft_revision > 0", name: "coach_content_packs_revision_positive"
    t.check_constraint "pack_kind::text = ANY (ARRAY['voice_culture'::character varying, 'coaching_method'::character varying, 'finance_reference'::character varying]::text[])", name: "coach_content_packs_kind_valid"
    t.check_constraint "scope::text = 'platform'::text AND coach_workspace_id IS NULL OR scope::text = 'coach'::text AND coach_workspace_id IS NOT NULL", name: "coach_content_packs_workspace_matches_scope"
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying, 'platform'::character varying]::text[])", name: "coach_content_packs_scope_valid"
  end

  create_table "coach_content_source_attempts", force: :cascade do |t|
    t.bigint "coach_content_source_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "error_code"
    t.string "error_message"
    t.integer "generation", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "model", null: false
    t.string "prompt_version", null: false
    t.string "provider", null: false
    t.string "schema_version", null: false
    t.datetime "started_at", null: false
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_content_source_id", "generation"], name: "idx_content_source_attempt_generation", unique: true
    t.index ["coach_content_source_id"], name: "index_coach_content_source_attempts_on_coach_content_source_id"
    t.check_constraint "generation > 0", name: "coach_content_source_attempt_generation_positive"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying, 'succeeded'::character varying, 'failed'::character varying, 'superseded'::character varying]::text[])", name: "coach_content_source_attempt_status_valid"
  end

  create_table "coach_content_source_candidates", force: :cascade do |t|
    t.bigint "accepted_content_item_id"
    t.bigint "coach_content_source_attempt_id", null: false
    t.bigint "coach_content_source_id", null: false
    t.text "content", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.text "evidence_excerpt", null: false
    t.jsonb "evidence_locator", default: {}, null: false
    t.string "kind", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "original_proposal_digest", null: false
    t.integer "position", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_user_id"
    t.integer "revision", default: 1, null: false
    t.string "safety_code"
    t.string "status", default: "proposed", null: false
    t.string "title", null: false
    t.jsonb "topics", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["accepted_content_item_id"], name: "idx_on_accepted_content_item_id_5be5b5577b"
    t.index ["coach_content_source_attempt_id", "position"], name: "idx_content_source_candidates_position", unique: true
    t.index ["coach_content_source_attempt_id"], name: "idx_on_coach_content_source_attempt_id_1c75bcd22c"
    t.index ["coach_content_source_id"], name: "idx_on_coach_content_source_id_f1dcfde3af"
    t.index ["reviewed_by_user_id"], name: "index_coach_content_source_candidates_on_reviewed_by_user_id"
    t.check_constraint "\"position\" >= 0 AND \"position\" < 30", name: "coach_content_source_candidates_position_valid"
    t.check_constraint "content_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_source_candidates_digest_sha256"
    t.check_constraint "jsonb_typeof(evidence_locator) = 'object'::text", name: "coach_content_source_candidates_locator_object"
    t.check_constraint "jsonb_typeof(topics) = 'array'::text AND jsonb_array_length(topics) <= 12", name: "coach_content_source_candidates_topics_bounded"
    t.check_constraint "octet_length(content) <= 12000", name: "coach_content_source_candidates_content_bytes"
    t.check_constraint "octet_length(evidence_excerpt) <= 1200", name: "coach_content_source_candidates_excerpt_bytes"
    t.check_constraint "original_proposal_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_source_candidates_original_digest_sha256"
    t.check_constraint "revision > 0", name: "coach_content_source_candidates_revision_positive"
    t.check_constraint "status::text = ANY (ARRAY['proposed'::character varying, 'accepted'::character varying, 'rejected'::character varying, 'superseded'::character varying]::text[])", name: "coach_content_source_candidates_status_valid"
  end

  create_table "coach_content_source_url_intake_attempts", force: :cascade do |t|
    t.bigint "coach_content_source_url_intake_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_content_source_url_intake_id"], name: "idx_url_intake_attempts_intake"
    t.index ["created_at"], name: "idx_url_intake_attempts_created_at"
  end

  create_table "coach_content_source_url_intakes", force: :cascade do |t|
    t.integer "cleanup_attempts", default: 0, null: false
    t.bigint "coach_content_source_id"
    t.bigint "coach_workspace_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.string "encrypted_url_auth_tag"
    t.text "encrypted_url_ciphertext"
    t.string "encrypted_url_iv"
    t.integer "encryption_key_version", null: false
    t.string "error_code"
    t.datetime "fetched_at"
    t.bigint "fetched_byte_size"
    t.string "fetched_checksum_sha256"
    t.string "final_s3_key"
    t.integer "hmac_key_version", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "redaction_requested_at"
    t.integer "redirect_count", default: 0, null: false
    t.string "request_id", null: false
    t.bigint "reserved_bytes", null: false
    t.string "resolved_content_type"
    t.string "resolved_filename"
    t.string "scope", default: "coach", null: false
    t.string "staging_s3_key"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.string "url_identity_hmac", null: false
    t.index ["coach_content_source_id"], name: "idx_on_coach_content_source_id_f2c735608e"
    t.index ["coach_content_source_id"], name: "idx_url_intakes_registered_source", unique: true, where: "(coach_content_source_id IS NOT NULL)"
    t.index ["coach_workspace_id", "request_id"], name: "idx_url_intakes_workspace_request", unique: true, where: "((scope)::text = 'coach'::text)"
    t.index ["coach_workspace_id"], name: "index_coach_content_source_url_intakes_on_coach_workspace_id"
    t.index ["created_by_user_id", "request_id"], name: "idx_url_intakes_platform_request", unique: true, where: "((scope)::text = 'platform'::text)"
    t.index ["created_by_user_id"], name: "index_coach_content_source_url_intakes_on_created_by_user_id"
    t.index ["final_s3_key"], name: "index_coach_content_source_url_intakes_on_final_s3_key", unique: true, where: "(final_s3_key IS NOT NULL)"
    t.index ["staging_s3_key"], name: "index_coach_content_source_url_intakes_on_staging_s3_key", unique: true, where: "(staging_s3_key IS NOT NULL)"
    t.index ["status", "updated_at"], name: "idx_url_intakes_recovery"
    t.index ["url_identity_hmac", "hmac_key_version"], name: "idx_url_intakes_hmac_version"
    t.check_constraint "fetched_checksum_sha256 IS NULL OR fetched_checksum_sha256::text ~ '^[0-9a-f]{64}$'::text", name: "url_intakes_checksum_sha256"
    t.check_constraint "redirect_count >= 0 AND redirect_count <= 3", name: "url_intakes_redirects_bounded"
    t.check_constraint "reserved_bytes > 0 AND reserved_bytes <= 12582912", name: "url_intakes_reservation_bounded"
    t.check_constraint "scope::text = 'coach'::text AND coach_workspace_id IS NOT NULL OR scope::text = 'platform'::text AND coach_workspace_id IS NULL", name: "url_intakes_workspace_matches_scope"
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying, 'platform'::character varying]::text[])", name: "url_intakes_scope_valid"
    t.check_constraint "status::text = 'deleted'::text OR redaction_requested_at IS NOT NULL OR encrypted_url_ciphertext IS NOT NULL AND encrypted_url_iv IS NOT NULL AND encrypted_url_auth_tag IS NOT NULL", name: "url_intakes_encrypted_payload_present"
    t.check_constraint "status::text = 'registered'::text AND coach_content_source_id IS NOT NULL OR status::text = 'deleted'::text OR (status::text <> ALL (ARRAY['registered'::character varying, 'deleted'::character varying]::text[])) AND coach_content_source_id IS NULL", name: "url_intakes_source_state_coherent"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'fetching'::character varying, 'staged'::character varying, 'registering'::character varying, 'registered'::character varying, 'failed'::character varying, 'cleanup_pending'::character varying, 'cleanup_failed'::character varying, 'deleted'::character varying]::text[])", name: "url_intakes_status_valid"
    t.check_constraint "url_identity_hmac::text ~ '^[0-9a-f]{64}$'::text", name: "url_intakes_hmac_sha256"
  end

  create_table "coach_content_sources", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum_sha256", null: false
    t.bigint "coach_workspace_id"
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "current_attempt_id"
    t.datetime "deletion_requested_at"
    t.string "error_code"
    t.string "error_message"
    t.string "filename", null: false
    t.integer "generation", default: 0, null: false
    t.string "ingestion_method", default: "upload", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "processed_at"
    t.jsonb "processing_metadata", default: {}, null: false
    t.string "s3_key"
    t.string "scope", default: "coach", null: false
    t.string "source_delete_error_code"
    t.datetime "source_deleted_at"
    t.bigint "source_deleted_by_user_id"
    t.string "status", default: "uploading", null: false
    t.datetime "updated_at", null: false
    t.string "upload_request_id", null: false
    t.index ["coach_workspace_id", "upload_request_id"], name: "idx_coach_content_sources_workspace_request", unique: true, where: "((scope)::text = 'coach'::text)"
    t.index ["coach_workspace_id"], name: "index_coach_content_sources_on_coach_workspace_id"
    t.index ["created_by_user_id", "upload_request_id"], name: "idx_platform_content_sources_owner_request", unique: true, where: "((scope)::text = 'platform'::text)"
    t.index ["created_by_user_id"], name: "index_coach_content_sources_on_created_by_user_id"
    t.index ["current_attempt_id"], name: "index_coach_content_sources_on_current_attempt_id"
    t.index ["s3_key"], name: "index_coach_content_sources_on_s3_key", unique: true, where: "(s3_key IS NOT NULL)"
    t.index ["source_deleted_by_user_id"], name: "index_coach_content_sources_on_source_deleted_by_user_id"
    t.check_constraint "byte_size > 0", name: "coach_content_sources_byte_size_positive"
    t.check_constraint "checksum_sha256::text ~ '^[0-9a-f]{64}$'::text", name: "coach_content_sources_checksum_sha256"
    t.check_constraint "generation >= 0", name: "coach_content_sources_generation_nonnegative"
    t.check_constraint "ingestion_method::text = ANY (ARRAY['upload'::character varying, 'url_snapshot'::character varying]::text[])", name: "coach_content_sources_ingestion_method_valid"
    t.check_constraint "scope::text = 'platform'::text AND coach_workspace_id IS NULL OR scope::text = 'coach'::text AND coach_workspace_id IS NOT NULL", name: "coach_content_sources_workspace_matches_scope"
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying, 'platform'::character varying]::text[])", name: "coach_content_sources_scope_valid"
    t.check_constraint "status::text = ANY (ARRAY['uploading'::character varying, 'verifying'::character varying, 'upload_cleanup'::character varying, 'queued'::character varying, 'processing'::character varying, 'needs_review'::character varying, 'failed'::character varying, 'deletion_pending'::character varying, 'deletion_failed'::character varying, 'source_deleted'::character varying, 'upload_cleanup_failed'::character varying]::text[])", name: "coach_content_sources_status_valid"
  end

  create_table "coach_operation_executions", force: :cascade do |t|
    t.string "actor_role_snapshot", null: false
    t.bigint "actor_user_id", null: false
    t.jsonb "after_snapshot", default: {}, null: false
    t.string "after_snapshot_digest", null: false
    t.jsonb "before_snapshot", default: {}, null: false
    t.string "before_snapshot_digest", null: false
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.bigint "cohort_release_id"
    t.bigint "cohort_rollout_transition_id"
    t.datetime "completed_at", null: false
    t.datetime "created_at", null: false
    t.string "invocation_fingerprint", null: false
    t.jsonb "normalized_input", default: {}, null: false
    t.string "normalized_input_digest", null: false
    t.string "operation_key", null: false
    t.integer "operation_version", null: false
    t.jsonb "predicted_after_snapshot", default: {}, null: false
    t.string "predicted_after_snapshot_digest", null: false
    t.string "request_fingerprint", null: false
    t.string "request_key", null: false
    t.string "source", default: "api", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_coach_operation_executions_on_actor_user_id"
    t.index ["coach_workspace_id"], name: "index_coach_operation_executions_on_coach_workspace_id"
    t.index ["cohort_id", "completed_at", "id"], name: "idx_coach_operations_history"
    t.index ["cohort_id", "request_key"], name: "idx_coach_operations_cohort_request", unique: true
    t.index ["cohort_id"], name: "index_coach_operation_executions_on_cohort_id"
    t.index ["cohort_release_id"], name: "idx_coach_operations_release_unique", unique: true
    t.index ["cohort_rollout_transition_id"], name: "idx_coach_operations_rollout_transition_unique", unique: true
    t.index ["id", "cohort_id", "coach_workspace_id"], name: "idx_coach_operations_id_cohort_workspace", unique: true
    t.check_constraint "(operation_key::text = ANY (ARRAY['cohort.release.seal'::character varying, 'cohort.release.restore'::character varying]::text[])) AND cohort_release_id IS NOT NULL AND cohort_rollout_transition_id IS NULL OR (operation_key::text = ANY (ARRAY['cohort.rollout.plan'::character varying, 'cohort.rollout.advance'::character varying, 'cohort.rollout.pause'::character varying, 'cohort.rollout.resume'::character varying, 'cohort.rollout.cancel'::character varying, 'cohort.rollout.rollback'::character varying]::text[])) AND cohort_release_id IS NULL AND cohort_rollout_transition_id IS NOT NULL", name: "coach_operations_result_matches_key"
    t.check_constraint "actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying, 'owner'::character varying, 'reviewer'::character varying]::text[])", name: "coach_operations_actor_role_valid"
    t.check_constraint "char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100", name: "coach_operations_request_key_bounded"
    t.check_constraint "invocation_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND request_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND normalized_input_digest::text ~ '^[0-9a-f]{64}$'::text AND before_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND predicted_after_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND after_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_operations_digest_shape"
    t.check_constraint "jsonb_typeof(normalized_input) = 'object'::text AND jsonb_typeof(before_snapshot) = 'object'::text AND jsonb_typeof(predicted_after_snapshot) = 'object'::text AND jsonb_typeof(after_snapshot) = 'object'::text", name: "coach_operations_json_shape"
    t.check_constraint "num_nonnulls(cohort_release_id, cohort_rollout_transition_id) = 1", name: "coach_operations_exactly_one_result"
    t.check_constraint "octet_length(normalized_input::text) <= 16384 AND octet_length(before_snapshot::text) <= 16384 AND octet_length(predicted_after_snapshot::text) <= 16384 AND octet_length(after_snapshot::text) <= 16384", name: "coach_operations_json_bounded"
    t.check_constraint "operation_key::text = ANY (ARRAY['cohort.release.seal'::character varying, 'cohort.release.restore'::character varying, 'cohort.rollout.plan'::character varying, 'cohort.rollout.advance'::character varying, 'cohort.rollout.pause'::character varying, 'cohort.rollout.resume'::character varying, 'cohort.rollout.cancel'::character varying, 'cohort.rollout.rollback'::character varying]::text[])", name: "coach_operations_key_valid"
    t.check_constraint "operation_version = ANY (ARRAY[1, 2])", name: "coach_operations_version_supported"
    t.check_constraint "source::text = 'api'::text", name: "coach_operations_source_valid"
  end

  create_table "coach_persona_behavioral_preview_evidences", force: :cascade do |t|
    t.string "candidate_digest", null: false
    t.bigint "coach_persona_release_candidate_id", null: false
    t.string "config_digest", null: false
    t.string "content_manifest_digest", null: false
    t.string "context_digest", null: false
    t.datetime "created_at", null: false
    t.string "evidence_digest", null: false
    t.datetime "generated_at", null: false
    t.bigint "generated_by_user_id", null: false
    t.string "model_identifier", null: false
    t.text "output", null: false
    t.string "phrase_manifest_digest", null: false
    t.string "privacy_scope", null: false
    t.text "prompt", null: false
    t.string "provider_request_id", null: false
    t.string "response_source", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_release_candidate_id"], name: "idx_persona_behavioral_previews_candidate"
    t.index ["evidence_digest"], name: "idx_persona_behavioral_previews_digest", unique: true
    t.index ["generated_by_user_id"], name: "idx_on_generated_by_user_id_90cd84d1a1"
    t.check_constraint "char_length(prompt) >= 1 AND char_length(prompt) <= 2000 AND char_length(output) >= 1 AND char_length(output) <= 4000 AND char_length(model_identifier::text) >= 1 AND char_length(model_identifier::text) <= 200 AND response_source::text = 'live_model'::text AND privacy_scope::text = 'no_saved_participant_or_household_data'::text", name: "persona_behavioral_previews_bounded"
    t.check_constraint "char_length(provider_request_id::text) >= 1 AND char_length(provider_request_id::text) <= 200 AND provider_request_id::text !~ '[[:space:][:cntrl:]]'::text", name: "persona_behavioral_previews_request_id_bounded"
    t.check_constraint "context_digest::text ~ '^[0-9a-f]{64}$'::text AND candidate_digest::text ~ '^[0-9a-f]{64}$'::text AND config_digest::text ~ '^[0-9a-f]{64}$'::text AND content_manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND phrase_manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_behavioral_previews_digest_shape"
    t.check_constraint "model_identifier::text !~ '[[:space:][:cntrl:]]'::text", name: "persona_behavioral_previews_model_identifier_concrete"
  end

  create_table "coach_persona_draft_content_packs", force: :cascade do |t|
    t.bigint "coach_content_pack_version_id", null: false
    t.bigint "coach_persona_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_content_pack_version_id"], name: "idx_on_coach_content_pack_version_id_77445a4bb5"
    t.index ["coach_persona_id", "coach_content_pack_version_id"], name: "idx_persona_draft_packs_version", unique: true
    t.index ["coach_persona_id", "position"], name: "idx_persona_draft_packs_position", unique: true
    t.index ["coach_persona_id"], name: "index_coach_persona_draft_content_packs_on_coach_persona_id"
  end

  create_table "coach_persona_draft_restore_events", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.bigint "coach_persona_id", null: false
    t.string "config_digest", null: false
    t.string "content_manifest_digest", null: false
    t.jsonb "content_pack_version_ids", default: [], null: false
    t.datetime "created_at", null: false
    t.string "event_digest", null: false
    t.jsonb "phrase_artifacts_snapshot", default: [], null: false
    t.string "phrase_manifest_digest", null: false
    t.integer "previous_draft_revision", null: false
    t.datetime "restored_at", null: false
    t.integer "restored_draft_revision", null: false
    t.bigint "source_version_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_coach_persona_draft_restore_events_on_actor_user_id"
    t.index ["coach_persona_id"], name: "index_coach_persona_draft_restore_events_on_coach_persona_id"
    t.index ["event_digest"], name: "idx_persona_draft_restore_events_digest", unique: true
    t.index ["source_version_id"], name: "index_coach_persona_draft_restore_events_on_source_version_id"
    t.check_constraint "config_digest::text ~ '^[0-9a-f]{64}$'::text AND content_manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND phrase_manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND event_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_draft_restore_events_digest_shape"
    t.check_constraint "jsonb_typeof(content_pack_version_ids) = 'array'::text AND jsonb_typeof(phrase_artifacts_snapshot) = 'array'::text", name: "persona_draft_restore_events_json_shape"
    t.check_constraint "previous_draft_revision > 0 AND restored_draft_revision = (previous_draft_revision + 1)", name: "persona_draft_restore_events_revision_sequence"
  end

  create_table "coach_persona_evaluation_approvals", force: :cascade do |t|
    t.string "approval_digest", null: false
    t.bigint "coach_persona_evaluation_run_id", null: false
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.datetime "reviewed_at", null: false
    t.bigint "reviewed_by_user_id", null: false
    t.string "reviewer_authority_digest"
    t.jsonb "reviewer_authority_snapshot", default: {}, null: false
    t.string "reviewer_role_snapshot"
    t.string "run_digest", null: false
    t.boolean "self_review", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_evaluation_run_id"], name: "idx_persona_evaluation_approvals_run", unique: true
    t.index ["reviewed_by_user_id"], name: "idx_on_reviewed_by_user_id_3507893542"
    t.check_constraint "decision::text = ANY (ARRAY['approved'::character varying, 'rejected'::character varying]::text[])", name: "persona_evaluation_approvals_decision_valid"
    t.check_constraint "reviewer_role_snapshot IS NULL AND reviewer_authority_digest IS NULL AND reviewer_authority_snapshot = '{}'::jsonb OR reviewer_role_snapshot IS NOT NULL AND reviewer_authority_digest::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(reviewer_authority_snapshot) = 'object'::text", name: "persona_evaluation_approvals_authority_shape"
    t.check_constraint "run_digest::text ~ '^[0-9a-f]{64}$'::text AND approval_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_evaluation_approvals_digest_shape"
  end

  create_table "coach_persona_evaluation_cases", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.jsonb "assertions", default: [], null: false
    t.string "case_digest", null: false
    t.string "case_kind", null: false
    t.bigint "coach_persona_id", null: false
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.string "name", null: false
    t.text "prompt", null: false
    t.string "request_fingerprint"
    t.string "request_key"
    t.boolean "required", default: false, null: false
    t.datetime "retired_at"
    t.bigint "retired_by_user_id"
    t.string "retirement_digest"
    t.string "system_key"
    t.datetime "updated_at", null: false
    t.index ["coach_persona_id", "system_key"], name: "idx_persona_evaluation_cases_system_key", unique: true, where: "(system_key IS NOT NULL)"
    t.index ["coach_persona_id"], name: "index_coach_persona_evaluation_cases_on_coach_persona_id"
    t.index ["coach_workspace_id"], name: "index_coach_persona_evaluation_cases_on_coach_workspace_id"
    t.index ["created_by_user_id"], name: "index_coach_persona_evaluation_cases_on_created_by_user_id"
    t.index ["request_key"], name: "idx_persona_evaluation_cases_request_key", unique: true, where: "(request_key IS NOT NULL)"
    t.index ["retired_by_user_id"], name: "index_coach_persona_evaluation_cases_on_retired_by_user_id"
    t.check_constraint "case_kind::text = ANY (ARRAY['system'::character varying, 'custom'::character varying]::text[])", name: "persona_evaluation_cases_kind_valid"
    t.check_constraint "jsonb_typeof(assertions) = 'array'::text AND (case_kind::text = 'system'::text AND required = true AND active = true AND system_key IS NOT NULL AND request_key IS NULL AND request_fingerprint IS NULL OR case_kind::text = 'custom'::text AND system_key IS NULL AND request_key IS NOT NULL AND char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100 AND request_fingerprint::text ~ '^[0-9a-f]{64}$'::text) AND (active = true AND retired_by_user_id IS NULL AND retired_at IS NULL AND retirement_digest IS NULL OR active = false AND case_kind::text = 'custom'::text AND retired_by_user_id IS NOT NULL AND retired_at IS NOT NULL AND retirement_digest::text ~ '^[0-9a-f]{64}$'::text)", name: "persona_evaluation_cases_shape"
  end

  create_table "coach_persona_evaluation_results", force: :cascade do |t|
    t.jsonb "adapter_metadata", default: {}, null: false
    t.jsonb "assertion_results", default: [], null: false
    t.jsonb "case_snapshot", default: {}, null: false
    t.bigint "coach_persona_evaluation_case_id", null: false
    t.bigint "coach_persona_evaluation_run_id", null: false
    t.datetime "created_at", null: false
    t.boolean "fallback_only", default: false, null: false
    t.text "output", default: "", null: false
    t.string "result_digest", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_evaluation_case_id"], name: "idx_persona_evaluation_results_case"
    t.index ["coach_persona_evaluation_run_id", "coach_persona_evaluation_case_id"], name: "idx_persona_evaluation_results_unique_case", unique: true
    t.index ["coach_persona_evaluation_run_id"], name: "idx_persona_evaluation_results_run"
    t.check_constraint "result_digest::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(case_snapshot) = 'object'::text AND jsonb_typeof(adapter_metadata) = 'object'::text AND jsonb_typeof(assertion_results) = 'array'::text", name: "persona_evaluation_results_shape"
    t.check_constraint "status::text = ANY (ARRAY['passed'::character varying, 'failed'::character varying, 'error'::character varying]::text[])", name: "persona_evaluation_results_status_valid"
  end

  create_table "coach_persona_evaluation_runs", force: :cascade do |t|
    t.string "adapter_kind", null: false
    t.string "cases_digest", null: false
    t.bigint "coach_persona_release_candidate_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "enqueued_at"
    t.integer "execution_attempts", default: 0, null: false
    t.datetime "heartbeat_at"
    t.datetime "lease_claimed_at"
    t.datetime "lease_expires_at"
    t.string "lease_token"
    t.string "request_fingerprint", null: false
    t.string "request_key", null: false
    t.bigint "requested_by_user_id", null: false
    t.string "run_digest"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_release_candidate_id"], name: "idx_persona_evaluation_runs_candidate"
    t.index ["lease_token"], name: "idx_persona_evaluation_runs_lease_token", unique: true, where: "(lease_token IS NOT NULL)"
    t.index ["request_key"], name: "idx_persona_evaluation_runs_request_key", unique: true
    t.index ["requested_by_user_id"], name: "index_coach_persona_evaluation_runs_on_requested_by_user_id"
    t.check_constraint "cases_digest::text ~ '^[0-9a-f]{64}$'::text AND request_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100 AND execution_attempts >= 0 AND (run_digest IS NULL OR run_digest::text ~ '^[0-9a-f]{64}$'::text) AND (status::text = 'pending'::text AND started_at IS NULL AND completed_at IS NULL AND run_digest IS NULL OR status::text = 'running'::text AND started_at IS NOT NULL AND completed_at IS NULL AND run_digest IS NULL OR (status::text = ANY (ARRAY['passed'::character varying, 'failed'::character varying, 'error'::character varying]::text[])) AND started_at IS NOT NULL AND completed_at IS NOT NULL AND run_digest IS NOT NULL)", name: "persona_evaluation_runs_lifecycle"
    t.check_constraint "lease_token IS NULL AND lease_expires_at IS NULL AND heartbeat_at IS NULL AND lease_claimed_at IS NULL OR lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND heartbeat_at IS NOT NULL", name: "persona_evaluation_runs_lease_complete"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'passed'::character varying, 'failed'::character varying, 'error'::character varying]::text[])", name: "persona_evaluation_runs_status_valid"
  end

  create_table "coach_persona_phrase_promotions", force: :cascade do |t|
    t.jsonb "artifact", default: {}, null: false
    t.string "artifact_fingerprint", null: false
    t.uuid "artifact_id", null: false
    t.bigint "coach_persona_id", null: false
    t.bigint "coach_phrase_attestation_id", null: false
    t.bigint "coach_phrase_proposal_id", null: false
    t.datetime "created_at", null: false
    t.datetime "promoted_at", null: false
    t.bigint "promoted_by_user_id", null: false
    t.string "promotion_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_id", "artifact_id"], name: "idx_phrase_promotions_persona_artifact", unique: true
    t.index ["coach_persona_id", "coach_phrase_proposal_id"], name: "idx_phrase_promotions_persona_proposal", unique: true
    t.index ["coach_persona_id"], name: "index_coach_persona_phrase_promotions_on_coach_persona_id"
    t.index ["coach_phrase_attestation_id"], name: "idx_on_coach_phrase_attestation_id_e5289c740e"
    t.index ["coach_phrase_proposal_id"], name: "idx_on_coach_phrase_proposal_id_0e33c03c02"
    t.index ["promoted_by_user_id"], name: "index_coach_persona_phrase_promotions_on_promoted_by_user_id"
    t.check_constraint "artifact_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND promotion_digest::text ~ '^[0-9a-f]{64}$'::text", name: "phrase_promotions_digests_sha256"
    t.check_constraint "jsonb_typeof(artifact) = 'object'::text", name: "phrase_promotions_artifact_object"
    t.check_constraint "octet_length(artifact::text) <= 4096", name: "phrase_promotions_artifact_size"
  end

  create_table "coach_persona_publication_events", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.bigint "coach_persona_id", null: false
    t.bigint "coach_persona_version_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.jsonb "phrase_audience_attestation_digests", default: [], null: false
    t.string "release_evidence_digest"
    t.string "release_gate_version", default: "gate_v1", null: false
    t.bigint "source_version_id"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_coach_persona_publication_events_on_actor_user_id"
    t.index ["coach_persona_id"], name: "index_coach_persona_publication_events_on_coach_persona_id"
    t.index ["coach_persona_version_id"], name: "idx_on_coach_persona_version_id_4ab8b00110"
    t.index ["source_version_id"], name: "index_coach_persona_publication_events_on_source_version_id"
    t.check_constraint "event_type::text = ANY (ARRAY['publish'::character varying, 'rollback'::character varying]::text[])", name: "coach_persona_publication_events_type_valid"
    t.check_constraint "jsonb_typeof(phrase_audience_attestation_digests) = 'array'::text", name: "persona_publication_events_audience_attestation_digests_array"
    t.check_constraint "release_gate_version::text = 'gate_v1'::text AND release_evidence_digest IS NULL OR release_gate_version::text = 'gate_v2'::text AND release_evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_publication_events_release_evidence_complete"
    t.check_constraint "release_gate_version::text = ANY (ARRAY['gate_v1'::character varying, 'gate_v2'::character varying]::text[])", name: "persona_publication_events_release_gate_valid"
  end

  create_table "coach_persona_release_candidates", force: :cascade do |t|
    t.string "audience_digest", null: false
    t.jsonb "audience_snapshot", default: {}, null: false
    t.bigint "coach_persona_id", null: false
    t.string "config_digest", null: false
    t.jsonb "config_snapshot", default: {}, null: false
    t.string "content_manifest_digest", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.integer "draft_revision", null: false
    t.jsonb "manifest", default: {}, null: false
    t.string "manifest_digest", null: false
    t.jsonb "phrase_artifacts_snapshot", default: [], null: false
    t.string "phrase_manifest_digest", null: false
    t.datetime "sealed_at", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_id", "manifest_digest"], name: "idx_persona_release_candidates_manifest", unique: true
    t.index ["coach_persona_id"], name: "index_coach_persona_release_candidates_on_coach_persona_id"
    t.index ["created_by_user_id"], name: "index_coach_persona_release_candidates_on_created_by_user_id"
    t.check_constraint "draft_revision > 0 AND config_digest::text ~ '^[0-9a-f]{64}$'::text AND content_manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND phrase_manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND audience_digest::text ~ '^[0-9a-f]{64}$'::text AND manifest_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_release_candidates_digest_shape"
    t.check_constraint "jsonb_typeof(audience_snapshot) = 'object'::text AND jsonb_typeof(config_snapshot) = 'object'::text AND jsonb_typeof(phrase_artifacts_snapshot) = 'array'::text AND jsonb_typeof(manifest) = 'object'::text", name: "persona_release_candidates_json_shape"
  end

  create_table "coach_persona_setup_proposals", force: :cascade do |t|
    t.jsonb "after_state", default: {}, null: false
    t.string "base_config_digest", null: false
    t.integer "base_draft_revision", null: false
    t.jsonb "before_state", default: {}, null: false
    t.bigint "coach_persona_setup_session_id", null: false
    t.bigint "coach_persona_setup_turn_id", null: false
    t.datetime "created_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.jsonb "operations", default: [], null: false
    t.string "prompt_version", null: false
    t.string "proposal_digest", null: false
    t.string "resolution_idempotency_key", limit: 200
    t.datetime "resolved_at"
    t.bigint "resolved_by_user_id"
    t.string "schema_version", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_setup_session_id", "resolution_idempotency_key"], name: "idx_persona_setup_proposals_resolution_key", unique: true, where: "(resolution_idempotency_key IS NOT NULL)"
    t.index ["coach_persona_setup_session_id"], name: "idx_persona_setup_proposals_one_pending", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["coach_persona_setup_session_id"], name: "idx_persona_setup_proposals_session"
    t.index ["coach_persona_setup_turn_id"], name: "idx_persona_setup_proposals_one_per_turn", unique: true
    t.index ["coach_persona_setup_turn_id"], name: "idx_persona_setup_proposals_turn"
    t.index ["resolved_by_user_id"], name: "index_coach_persona_setup_proposals_on_resolved_by_user_id"
    t.check_constraint "(status::text = ANY (ARRAY['pending'::character varying, 'superseded'::character varying, 'stale'::character varying]::text[])) OR resolution_idempotency_key IS NOT NULL", name: "persona_setup_proposals_user_resolution_key_present"
    t.check_constraint "base_config_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_setup_proposals_base_digest_sha256"
    t.check_constraint "base_draft_revision > 0", name: "persona_setup_proposals_revision_positive"
    t.check_constraint "jsonb_typeof(before_state) = 'object'::text AND jsonb_typeof(after_state) = 'object'::text", name: "persona_setup_proposals_states_objects"
    t.check_constraint "jsonb_typeof(operations) = 'array'::text AND jsonb_array_length(operations) <= 24", name: "persona_setup_proposals_operations_array"
    t.check_constraint "octet_length(operations::text) <= 32768 AND octet_length(before_state::text) <= 65536 AND octet_length(after_state::text) <= 65536", name: "persona_setup_proposals_payload_sizes"
    t.check_constraint "proposal_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_setup_proposals_digest_sha256"
    t.check_constraint "status::text = 'pending'::text AND resolved_by_user_id IS NULL AND resolved_at IS NULL OR status::text <> 'pending'::text AND resolved_by_user_id IS NOT NULL AND resolved_at IS NOT NULL", name: "persona_setup_proposals_resolution_complete"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'applied'::character varying, 'rejected'::character varying, 'superseded'::character varying, 'stale'::character varying]::text[])", name: "persona_setup_proposals_status_valid"
  end

  create_table "coach_persona_setup_sessions", force: :cascade do |t|
    t.string "base_config_digest", null: false
    t.integer "base_draft_revision", null: false
    t.bigint "coach_persona_id", null: false
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.datetime "last_activity_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_id", "created_by_user_id"], name: "idx_persona_setup_sessions_one_active", unique: true, where: "((status)::text = 'active'::text)"
    t.index ["coach_persona_id"], name: "index_coach_persona_setup_sessions_on_coach_persona_id"
    t.index ["coach_workspace_id"], name: "index_coach_persona_setup_sessions_on_coach_workspace_id"
    t.index ["created_by_user_id"], name: "index_coach_persona_setup_sessions_on_created_by_user_id"
    t.index ["id", "coach_workspace_id"], name: "idx_persona_setup_sessions_id_workspace", unique: true
    t.check_constraint "base_config_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_setup_sessions_digest_sha256"
    t.check_constraint "base_draft_revision > 0", name: "persona_setup_sessions_revision_positive"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'completed'::character varying, 'abandoned'::character varying]::text[])", name: "persona_setup_sessions_status_valid"
  end

  create_table "coach_persona_setup_turns", force: :cascade do |t|
    t.text "assistant_message"
    t.string "base_config_digest", null: false
    t.integer "base_draft_revision", null: false
    t.bigint "coach_persona_setup_session_id", null: false
    t.datetime "created_at", null: false
    t.string "error_code"
    t.string "idempotency_key", limit: 200, null: false
    t.string "model"
    t.integer "position", null: false
    t.string "prompt_version"
    t.string "provider"
    t.string "schema_version"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.jsonb "usage", default: {}, null: false
    t.text "user_message", null: false
    t.index ["coach_persona_setup_session_id", "idempotency_key"], name: "idx_persona_setup_turns_idempotency", unique: true
    t.index ["coach_persona_setup_session_id", "position"], name: "idx_persona_setup_turns_position", unique: true
    t.index ["coach_persona_setup_session_id"], name: "idx_persona_setup_turns_one_processing", unique: true, where: "((status)::text = 'processing'::text)"
    t.index ["coach_persona_setup_session_id"], name: "idx_persona_setup_turns_session"
    t.index ["id", "coach_persona_setup_session_id"], name: "idx_persona_setup_turns_id_session", unique: true
    t.check_constraint "(status::text <> 'processing'::text OR assistant_message IS NULL AND error_code IS NULL) AND (status::text <> 'ready'::text OR assistant_message IS NOT NULL AND error_code IS NULL) AND (status::text <> 'failed'::text OR error_code IS NOT NULL)", name: "persona_setup_turns_state_coherent"
    t.check_constraint "\"position\" > 0", name: "persona_setup_turns_position_positive"
    t.check_constraint "assistant_message IS NULL OR char_length(assistant_message) <= 2000", name: "persona_setup_turns_assistant_message_length"
    t.check_constraint "base_config_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_setup_turns_digest_sha256"
    t.check_constraint "base_draft_revision > 0", name: "persona_setup_turns_revision_positive"
    t.check_constraint "char_length(user_message) >= 1 AND char_length(user_message) <= 4000", name: "persona_setup_turns_user_message_length"
    t.check_constraint "error_code IS NULL OR char_length(error_code::text) >= 1 AND char_length(error_code::text) <= 80", name: "persona_setup_turns_error_code_length"
    t.check_constraint "jsonb_typeof(usage) = 'object'::text", name: "persona_setup_turns_usage_object"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying, 'ready'::character varying, 'failed'::character varying, 'stale'::character varying]::text[])", name: "persona_setup_turns_status_valid"
  end

  create_table "coach_persona_version_content_packs", force: :cascade do |t|
    t.bigint "coach_content_pack_version_id", null: false
    t.bigint "coach_persona_version_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_content_pack_version_id"], name: "idx_on_coach_content_pack_version_id_a2cf520e02"
    t.index ["coach_persona_version_id", "coach_content_pack_version_id"], name: "idx_persona_version_packs_version", unique: true
    t.index ["coach_persona_version_id", "position"], name: "idx_persona_version_packs_position", unique: true
    t.index ["coach_persona_version_id"], name: "idx_on_coach_persona_version_id_08a3a5cabb"
  end

  create_table "coach_persona_version_phrase_artifacts", force: :cascade do |t|
    t.string "artifact_fingerprint", null: false
    t.uuid "artifact_id", null: false
    t.bigint "coach_persona_phrase_promotion_id", null: false
    t.bigint "coach_persona_version_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.string "promotion_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_phrase_promotion_id"], name: "idx_persona_version_phrase_links_promotion"
    t.index ["coach_persona_version_id", "artifact_id"], name: "idx_persona_version_phrase_links_artifact", unique: true
    t.index ["coach_persona_version_id", "position"], name: "idx_persona_version_phrase_links_position", unique: true
    t.index ["coach_persona_version_id"], name: "idx_persona_version_phrase_links_version"
    t.check_constraint "\"position\" >= 0", name: "persona_version_phrase_links_position_nonnegative"
    t.check_constraint "artifact_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND promotion_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_version_phrase_links_digests_sha256"
  end

  create_table "coach_persona_versions", force: :cascade do |t|
    t.string "audience_digest"
    t.string "behavioral_preview_digest"
    t.bigint "coach_persona_behavioral_preview_evidence_id"
    t.bigint "coach_persona_evaluation_approval_id"
    t.bigint "coach_persona_evaluation_run_id"
    t.bigint "coach_persona_id", null: false
    t.bigint "coach_persona_release_candidate_id"
    t.jsonb "config", null: false
    t.string "config_digest", null: false
    t.string "content_manifest_digest", default: "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945", null: false
    t.datetime "created_at", null: false
    t.jsonb "phrase_audience_attestation_digests", default: [], null: false
    t.string "phrase_manifest_digest", default: "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945", null: false
    t.bigint "published_by_user_id", null: false
    t.string "release_evidence_digest"
    t.string "release_evidence_schema"
    t.string "release_gate_version", default: "gate_v1", null: false
    t.string "release_manifest_digest"
    t.datetime "sealed_at"
    t.bigint "source_version_id"
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["coach_persona_behavioral_preview_evidence_id"], name: "idx_persona_versions_behavioral_preview"
    t.index ["coach_persona_evaluation_approval_id"], name: "idx_persona_versions_evaluation_approval"
    t.index ["coach_persona_evaluation_run_id"], name: "idx_persona_versions_evaluation_run"
    t.index ["coach_persona_id", "version_number"], name: "index_coach_persona_versions_on_persona_and_number", unique: true
    t.index ["coach_persona_id"], name: "index_coach_persona_versions_on_coach_persona_id"
    t.index ["coach_persona_release_candidate_id"], name: "idx_persona_versions_release_candidate"
    t.index ["id", "coach_persona_id"], name: "idx_persona_versions_id_persona", unique: true
    t.index ["published_by_user_id"], name: "index_coach_persona_versions_on_published_by_user_id"
    t.index ["source_version_id"], name: "index_coach_persona_versions_on_source_version_id"
    t.check_constraint "NOT (config #> '{response_shape,validate_before_coaching}'::text[]) IS DISTINCT FROM 'true'::jsonb AND NOT (config #> '{response_shape,next_move_required}'::text[]) IS DISTINCT FROM 'true'::jsonb", name: "coach_persona_versions_response_invariants_true"
    t.check_constraint "config_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_persona_versions_digest_sha256"
    t.check_constraint "content_manifest_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_persona_versions_content_manifest_sha256"
    t.check_constraint "jsonb_typeof(config) = 'object'::text", name: "coach_persona_versions_config_object"
    t.check_constraint "jsonb_typeof(phrase_audience_attestation_digests) = 'array'::text", name: "persona_versions_audience_attestation_digests_array"
    t.check_constraint "octet_length(config::text) <= 49152", name: "coach_persona_versions_config_bytes"
    t.check_constraint "phrase_manifest_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_persona_versions_phrase_manifest_sha256"
    t.check_constraint "release_gate_version::text = 'gate_v1'::text AND coach_persona_release_candidate_id IS NULL AND coach_persona_evaluation_run_id IS NULL AND coach_persona_evaluation_approval_id IS NULL AND release_manifest_digest IS NULL AND audience_digest IS NULL AND release_evidence_digest IS NULL OR release_gate_version::text = 'gate_v2'::text AND coach_persona_release_candidate_id IS NOT NULL AND coach_persona_evaluation_run_id IS NOT NULL AND coach_persona_evaluation_approval_id IS NOT NULL AND release_manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND audience_digest::text ~ '^[0-9a-f]{64}$'::text AND release_evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_versions_release_evidence_complete"
    t.check_constraint "release_gate_version::text = 'gate_v1'::text AND release_evidence_schema IS NULL AND coach_persona_behavioral_preview_evidence_id IS NULL AND behavioral_preview_digest IS NULL OR release_gate_version::text = 'gate_v2'::text AND (release_evidence_schema::text = ANY (ARRAY['persona_release_evidence_v2'::character varying, 'persona_release_evidence_v3'::character varying]::text[])) AND (release_evidence_schema::text = 'persona_release_evidence_v2'::text AND coach_persona_behavioral_preview_evidence_id IS NULL AND behavioral_preview_digest IS NULL OR release_evidence_schema::text = 'persona_release_evidence_v3'::text AND coach_persona_behavioral_preview_evidence_id IS NOT NULL AND behavioral_preview_digest::text ~ '^[0-9a-f]{64}$'::text)", name: "persona_versions_behavioral_preview_shape"
    t.check_constraint "release_gate_version::text = ANY (ARRAY['gate_v1'::character varying, 'gate_v2'::character varying]::text[])", name: "persona_versions_release_gate_valid"
    t.check_constraint "version_number > 0", name: "coach_persona_versions_positive_number"
  end

  create_table "coach_personas", force: :cascade do |t|
    t.datetime "archived_at"
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "current_published_version_id"
    t.text "description"
    t.jsonb "draft_config", default: {}, null: false
    t.integer "draft_revision", default: 1, null: false
    t.integer "lock_version", default: 0, null: false
    t.string "name", null: false
    t.string "preview_digest"
    t.datetime "previewed_at"
    t.integer "previewed_draft_revision"
    t.string "release_gate_version", default: "gate_v1", null: false
    t.datetime "updated_at", null: false
    t.index "coach_workspace_id, lower((name)::text)", name: "index_coach_personas_on_workspace_and_lower_name", unique: true
    t.index ["archived_at"], name: "index_coach_personas_on_archived_at"
    t.index ["coach_workspace_id"], name: "index_coach_personas_on_coach_workspace_id"
    t.index ["created_by_user_id"], name: "index_coach_personas_on_created_by_user_id"
    t.index ["current_published_version_id"], name: "index_coach_personas_on_current_published_version_id"
    t.index ["id", "coach_workspace_id"], name: "idx_personas_id_workspace", unique: true
    t.check_constraint "NOT (draft_config #> '{response_shape,validate_before_coaching}'::text[]) IS DISTINCT FROM 'true'::jsonb AND NOT (draft_config #> '{response_shape,next_move_required}'::text[]) IS DISTINCT FROM 'true'::jsonb", name: "coach_personas_response_invariants_true"
    t.check_constraint "draft_revision > 0", name: "coach_personas_positive_draft_revision"
    t.check_constraint "jsonb_typeof(draft_config) = 'object'::text", name: "coach_personas_draft_config_object"
    t.check_constraint "octet_length(draft_config::text) <= 49152", name: "coach_personas_draft_config_bytes"
    t.check_constraint "preview_digest IS NULL AND previewed_at IS NULL AND previewed_draft_revision IS NULL OR preview_digest IS NOT NULL AND previewed_at IS NOT NULL AND previewed_draft_revision IS NOT NULL", name: "coach_personas_preview_fields_complete"
    t.check_constraint "preview_digest IS NULL OR preview_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_personas_preview_digest_sha256"
    t.check_constraint "release_gate_version::text = ANY (ARRAY['gate_v1'::character varying, 'gate_v2'::character varying]::text[])", name: "coach_personas_release_gate_valid"
  end

  create_table "coach_phrase_attestations", force: :cascade do |t|
    t.string "attestation_digest", null: false
    t.bigint "coach_phrase_proposal_id", null: false
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.string "evidence_digest", null: false
    t.string "proposal_digest", null: false
    t.datetime "reviewed_at", null: false
    t.bigint "reviewed_by_user_id", null: false
    t.boolean "self_review", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["coach_phrase_proposal_id"], name: "index_coach_phrase_attestations_on_coach_phrase_proposal_id", unique: true
    t.index ["reviewed_by_user_id"], name: "index_coach_phrase_attestations_on_reviewed_by_user_id"
    t.check_constraint "decision::text = ANY (ARRAY['approved'::character varying, 'rejected'::character varying]::text[])", name: "phrase_attestations_decision_valid"
    t.check_constraint "proposal_digest::text ~ '^[0-9a-f]{64}$'::text AND evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND attestation_digest::text ~ '^[0-9a-f]{64}$'::text", name: "phrase_attestations_digests_sha256"
  end

  create_table "coach_phrase_audience_attestations", force: :cascade do |t|
    t.string "artifact_fingerprint", null: false
    t.uuid "artifact_id", null: false
    t.string "attestation_digest", null: false
    t.string "audience_digest", null: false
    t.bigint "coach_persona_release_candidate_id", null: false
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.datetime "reviewed_at", null: false
    t.bigint "reviewed_by_user_id", null: false
    t.string "reviewer_authority_digest"
    t.jsonb "reviewer_authority_snapshot", default: {}, null: false
    t.string "reviewer_role_snapshot"
    t.boolean "self_review", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["coach_persona_release_candidate_id", "artifact_id", "reviewed_at", "id"], name: "idx_phrase_audience_attestations_effective"
    t.index ["coach_persona_release_candidate_id"], name: "idx_phrase_audience_attestations_candidate"
    t.index ["reviewed_by_user_id"], name: "idx_on_reviewed_by_user_id_4e3698fda7"
    t.check_constraint "artifact_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND audience_digest::text ~ '^[0-9a-f]{64}$'::text AND attestation_digest::text ~ '^[0-9a-f]{64}$'::text", name: "phrase_audience_attestations_digest_shape"
    t.check_constraint "decision::text = ANY (ARRAY['approved'::character varying, 'rejected'::character varying]::text[])", name: "phrase_audience_attestations_decision_valid"
    t.check_constraint "reviewer_role_snapshot IS NULL AND reviewer_authority_digest IS NULL AND reviewer_authority_snapshot = '{}'::jsonb OR reviewer_role_snapshot IS NOT NULL AND reviewer_authority_digest::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(reviewer_authority_snapshot) = 'object'::text", name: "phrase_audience_attestations_authority_shape"
  end

  create_table "coach_phrase_proposals", force: :cascade do |t|
    t.string "approved_content_digest", null: false
    t.bigint "coach_content_item_version_id", null: false
    t.bigint "coach_content_source_attempt_id", null: false
    t.bigint "coach_content_source_candidate_id", null: false
    t.bigint "coach_content_source_id", null: false
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "evidence_end_byte", null: false
    t.jsonb "evidence_locator", default: {}, null: false
    t.bigint "evidence_start_byte", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "phrase_digest", null: false
    t.jsonb "phrase_payload", default: {}, null: false
    t.string "proposal_digest", null: false
    t.bigint "proposed_by_user_id", null: false
    t.integer "revision", default: 1, null: false
    t.string "source_checksum_sha256", null: false
    t.string "source_provenance_digest", null: false
    t.string "source_segment_digest", null: false
    t.string "status", default: "draft", null: false
    t.datetime "submitted_at"
    t.datetime "superseded_at"
    t.datetime "updated_at", null: false
    t.index ["coach_content_item_version_id"], name: "index_coach_phrase_proposals_on_coach_content_item_version_id"
    t.index ["coach_content_source_attempt_id"], name: "idx_on_coach_content_source_attempt_id_c701b59aa7"
    t.index ["coach_content_source_candidate_id"], name: "idx_on_coach_content_source_candidate_id_566e5765de"
    t.index ["coach_content_source_id", "status"], name: "idx_phrase_proposals_source_status"
    t.index ["coach_content_source_id"], name: "index_coach_phrase_proposals_on_coach_content_source_id"
    t.index ["coach_workspace_id", "proposal_digest"], name: "idx_phrase_proposals_workspace_digest", unique: true
    t.index ["coach_workspace_id"], name: "index_coach_phrase_proposals_on_coach_workspace_id"
    t.index ["proposed_by_user_id"], name: "index_coach_phrase_proposals_on_proposed_by_user_id"
    t.check_constraint "evidence_start_byte >= 0 AND evidence_end_byte > evidence_start_byte", name: "phrase_proposals_evidence_offsets_valid"
    t.check_constraint "jsonb_typeof(evidence_locator) = 'object'::text", name: "phrase_proposals_locator_object"
    t.check_constraint "jsonb_typeof(phrase_payload) = 'object'::text", name: "phrase_proposals_payload_object"
    t.check_constraint "octet_length(phrase_payload::text) <= 4096 AND octet_length(evidence_locator::text) <= 2048", name: "phrase_proposals_payload_sizes"
    t.check_constraint "revision > 0", name: "phrase_proposals_revision_positive"
    t.check_constraint "source_checksum_sha256::text ~ '^[0-9a-f]{64}$'::text AND source_segment_digest::text ~ '^[0-9a-f]{64}$'::text AND phrase_digest::text ~ '^[0-9a-f]{64}$'::text AND approved_content_digest::text ~ '^[0-9a-f]{64}$'::text AND source_provenance_digest::text ~ '^[0-9a-f]{64}$'::text AND proposal_digest::text ~ '^[0-9a-f]{64}$'::text", name: "phrase_proposals_digests_sha256"
    t.check_constraint "status::text = 'draft'::text AND submitted_at IS NULL OR (status::text = ANY (ARRAY['submitted'::character varying, 'rejected'::character varying]::text[])) AND submitted_at IS NOT NULL OR status::text = 'superseded'::text", name: "phrase_proposals_submission_coherent"
    t.check_constraint "status::text = 'superseded'::text AND superseded_at IS NOT NULL OR status::text <> 'superseded'::text AND superseded_at IS NULL", name: "phrase_proposals_supersession_coherent"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'submitted'::character varying, 'rejected'::character varying, 'superseded'::character varying]::text[])", name: "phrase_proposals_status_valid"
  end

  create_table "coach_profiles", force: :cascade do |t|
    t.text "bio"
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.bigint "last_edited_by_user_id"
    t.string "title", default: "Financial coach", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_workspace_id"], name: "index_coach_profiles_on_coach_workspace_id", unique: true
    t.index ["last_edited_by_user_id"], name: "index_coach_profiles_on_last_edited_by_user_id"
    t.check_constraint "bio IS NULL OR char_length(bio) <= 2000", name: "coach_profiles_bio_length"
    t.check_constraint "char_length(display_name::text) >= 1 AND char_length(display_name::text) <= 120", name: "coach_profiles_display_name_length"
    t.check_constraint "char_length(title::text) >= 1 AND char_length(title::text) <= 160", name: "coach_profiles_title_length"
  end

  create_table "coach_workspace_domain_events", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.bigint "coach_workspace_domain_id", null: false
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_coach_workspace_domain_events_on_actor_user_id"
    t.index ["coach_workspace_domain_id"], name: "idx_coach_workspace_domain_events_domain"
    t.check_constraint "event_type::text = ANY (ARRAY['created'::character varying, 'verification_requested'::character varying, 'verified'::character varying, 'activated'::character varying, 'disabled'::character varying]::text[])", name: "coach_workspace_domain_events_type"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "coach_workspace_domain_events_metadata_object"
    t.check_constraint "octet_length(metadata::text) <= 4096", name: "coach_workspace_domain_events_metadata_bytes"
  end

  create_table "coach_workspace_domains", force: :cascade do |t|
    t.datetime "activated_at"
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.datetime "disabled_at"
    t.string "hostname", null: false
    t.boolean "is_primary", default: false, null: false
    t.string "kind", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_user_id", null: false
    t.datetime "verification_requested_at"
    t.string "verification_token_digest"
    t.datetime "verified_at"
    t.index "lower((hostname)::text)", name: "idx_coach_workspace_domains_lower_hostname", unique: true
    t.index ["coach_workspace_id"], name: "idx_coach_workspace_domains_one_primary", unique: true, where: "is_primary"
    t.index ["coach_workspace_id"], name: "index_coach_workspace_domains_on_coach_workspace_id"
    t.index ["created_by_user_id"], name: "index_coach_workspace_domains_on_created_by_user_id"
    t.index ["id", "coach_workspace_id"], name: "idx_coach_workspace_domains_id_workspace", unique: true
    t.index ["updated_by_user_id"], name: "index_coach_workspace_domains_on_updated_by_user_id"
    t.check_constraint "(status::text <> ALL (ARRAY['verified'::character varying, 'active'::character varying]::text[])) OR verified_at IS NOT NULL", name: "coach_workspace_domains_verified_evidence"
    t.check_constraint "(status::text = 'disabled'::text) = (disabled_at IS NOT NULL)", name: "coach_workspace_domains_disabled_evidence"
    t.check_constraint "NOT is_primary OR status::text = 'active'::text", name: "coach_workspace_domains_primary_active"
    t.check_constraint "char_length(hostname::text) >= 4 AND char_length(hostname::text) <= 253", name: "coach_workspace_domains_hostname_length"
    t.check_constraint "hostname::text = lower(hostname::text) AND hostname::text ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$'::text", name: "coach_workspace_domains_hostname"
    t.check_constraint "kind::text = ANY (ARRAY['managed_subdomain'::character varying, 'custom'::character varying]::text[])", name: "coach_workspace_domains_kind"
    t.check_constraint "status::text <> 'active'::text OR activated_at IS NOT NULL", name: "coach_workspace_domains_active_evidence"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'verified'::character varying, 'active'::character varying, 'disabled'::character varying]::text[])", name: "coach_workspace_domains_status"
    t.check_constraint "verification_token_digest IS NULL OR verification_token_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_workspace_domains_token_digest"
  end

  create_table "coach_workspace_membership_events", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.string "after_role"
    t.string "before_role"
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "subject_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_coach_workspace_membership_events_on_actor_user_id"
    t.index ["coach_workspace_id"], name: "index_coach_workspace_membership_events_on_coach_workspace_id"
    t.index ["subject_user_id"], name: "index_coach_workspace_membership_events_on_subject_user_id"
    t.check_constraint "after_role IS NULL OR (after_role::text = ANY (ARRAY['owner'::character varying, 'editor'::character varying, 'reviewer'::character varying, 'viewer'::character varying]::text[]))", name: "workspace_membership_event_after_role"
    t.check_constraint "before_role IS NULL OR (before_role::text = ANY (ARRAY['owner'::character varying, 'editor'::character varying, 'reviewer'::character varying, 'viewer'::character varying]::text[]))", name: "workspace_membership_event_before_role"
    t.check_constraint "event_type::text = ANY (ARRAY['added'::character varying, 'role_changed'::character varying, 'removed'::character varying]::text[])", name: "workspace_membership_event_type"
  end

  create_table "coach_workspace_memberships", force: :cascade do |t|
    t.bigint "coach_workspace_id", null: false
    t.boolean "cohort_managed", default: false, null: false
    t.datetime "created_at", null: false
    t.string "role", default: "viewer", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["coach_workspace_id", "user_id"], name: "index_coach_workspace_memberships_unique_user", unique: true
    t.index ["coach_workspace_id"], name: "index_coach_workspace_memberships_on_coach_workspace_id"
    t.index ["user_id"], name: "index_coach_workspace_memberships_on_user_id"
    t.check_constraint "role::text = ANY (ARRAY['owner'::character varying, 'editor'::character varying, 'reviewer'::character varying, 'viewer'::character varying]::text[])", name: "coach_workspace_memberships_role_valid"
  end

  create_table "coach_workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.string "creation_request_fingerprint"
    t.string "creation_request_key"
    t.integer "lock_version", default: 0, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index "lower((slug)::text)", name: "index_coach_workspaces_on_lower_slug", unique: true
    t.index ["created_by_user_id", "creation_request_key"], name: "idx_coach_workspaces_creation_request", unique: true, where: "(creation_request_key IS NOT NULL)"
    t.index ["created_by_user_id"], name: "index_coach_workspaces_on_created_by_user_id"
  end

  create_table "cohort_experience_configurations", force: :cascade do |t|
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.datetime "created_at", null: false
    t.bigint "current_published_version_id"
    t.jsonb "draft_config", default: {}, null: false
    t.integer "draft_revision", default: 1, null: false
    t.bigint "last_edited_by_user_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "preview_digest"
    t.datetime "previewed_at"
    t.integer "previewed_draft_revision"
    t.datetime "updated_at", null: false
    t.index ["coach_workspace_id"], name: "index_cohort_experience_configurations_on_coach_workspace_id"
    t.index ["cohort_id"], name: "index_cohort_experience_configurations_on_cohort_id", unique: true
    t.index ["current_published_version_id"], name: "idx_on_current_published_version_id_c3dd196ade"
    t.index ["id", "cohort_id", "coach_workspace_id"], name: "idx_experience_configurations_id_cohort_workspace", unique: true
    t.index ["last_edited_by_user_id"], name: "idx_on_last_edited_by_user_id_f58c8a3820"
    t.check_constraint "draft_revision > 0", name: "cohort_experience_configurations_positive_revision"
    t.check_constraint "jsonb_typeof(draft_config) = 'object'::text", name: "cohort_experience_configurations_draft_object"
    t.check_constraint "octet_length(draft_config::text) <= 4096", name: "cohort_experience_configurations_draft_bytes"
    t.check_constraint "preview_digest IS NULL AND previewed_draft_revision IS NULL AND previewed_at IS NULL OR preview_digest IS NOT NULL AND previewed_draft_revision IS NOT NULL AND previewed_at IS NOT NULL", name: "cohort_experience_configurations_preview_complete"
    t.check_constraint "preview_digest IS NULL OR preview_digest::text ~ '^[0-9a-f]{64}$'::text", name: "cohort_experience_configurations_preview_digest"
  end

  create_table "cohort_experience_publication_events", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.bigint "cohort_experience_configuration_id", null: false
    t.bigint "cohort_experience_version_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "source_version_id"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_cohort_experience_publication_events_on_actor_user_id"
    t.index ["cohort_experience_configuration_id"], name: "index_cohort_experience_events_on_configuration"
    t.index ["cohort_experience_version_id"], name: "index_cohort_experience_events_on_version"
    t.index ["source_version_id"], name: "idx_on_source_version_id_eaa4a993fe"
    t.check_constraint "event_type::text = ANY (ARRAY['publish'::character varying, 'rollback'::character varying]::text[])", name: "cohort_experience_publication_events_type"
  end

  create_table "cohort_experience_versions", force: :cascade do |t|
    t.bigint "cohort_experience_configuration_id", null: false
    t.jsonb "config", null: false
    t.string "config_digest", null: false
    t.datetime "created_at", null: false
    t.bigint "published_by_user_id", null: false
    t.bigint "source_version_id"
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["cohort_experience_configuration_id", "version_number"], name: "index_cohort_experience_versions_on_config_and_number", unique: true
    t.index ["id", "cohort_experience_configuration_id"], name: "idx_experience_versions_id_configuration", unique: true
    t.index ["published_by_user_id"], name: "index_cohort_experience_versions_on_published_by_user_id"
    t.index ["source_version_id"], name: "index_cohort_experience_versions_on_source_version_id"
    t.check_constraint "config_digest::text ~ '^[0-9a-f]{64}$'::text", name: "cohort_experience_versions_digest"
    t.check_constraint "jsonb_typeof(config) = 'object'::text", name: "cohort_experience_versions_config_object"
    t.check_constraint "octet_length(config::text) <= 4096", name: "cohort_experience_versions_config_bytes"
    t.check_constraint "version_number > 0", name: "cohort_experience_versions_positive_number"
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

  create_table "cohort_persona_assignments", force: :cascade do |t|
    t.bigint "assigned_by_user_id", null: false
    t.bigint "coach_persona_id", null: false
    t.bigint "coach_persona_version_id", null: false
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_by_user_id"], name: "index_cohort_persona_assignments_on_assigned_by_user_id"
    t.index ["coach_persona_id"], name: "index_cohort_persona_assignments_on_coach_persona_id"
    t.index ["coach_persona_version_id"], name: "index_cohort_persona_assignments_on_coach_persona_version_id"
    t.index ["coach_workspace_id"], name: "index_cohort_persona_assignments_on_coach_workspace_id"
    t.index ["cohort_id"], name: "index_cohort_persona_assignments_on_cohort_id", unique: true
  end

  create_table "cohort_release_activation_events", force: :cascade do |t|
    t.string "actor_role_snapshot"
    t.bigint "actor_user_id"
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.bigint "cohort_rollout_id"
    t.bigint "cohort_rollout_transition_id"
    t.datetime "created_at", null: false
    t.bigint "database_transaction_id", null: false
    t.string "event_type", null: false
    t.bigint "from_cohort_release_id"
    t.datetime "occurred_at", null: false
    t.string "request_fingerprint", null: false
    t.string "request_key", null: false
    t.bigint "to_cohort_release_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_cohort_release_activation_events_on_actor_user_id"
    t.index ["coach_workspace_id"], name: "index_cohort_release_activation_events_on_coach_workspace_id"
    t.index ["cohort_id", "occurred_at", "id"], name: "idx_release_activation_events_history"
    t.index ["cohort_id", "request_key"], name: "idx_release_activation_events_request", unique: true
    t.index ["cohort_id"], name: "index_cohort_release_activation_events_on_cohort_id"
    t.index ["cohort_rollout_id"], name: "index_cohort_release_activation_events_on_cohort_rollout_id"
    t.index ["cohort_rollout_transition_id"], name: "idx_on_cohort_rollout_transition_id_b1fe68dd2e"
    t.index ["from_cohort_release_id"], name: "idx_on_from_cohort_release_id_13d9f68065"
    t.index ["id", "cohort_id", "coach_workspace_id"], name: "idx_release_activation_events_scope", unique: true
    t.index ["to_cohort_release_id"], name: "index_cohort_release_activation_events_on_to_cohort_release_id"
    t.check_constraint "event_type::text = 'backfill'::text AND cohort_rollout_id IS NULL AND cohort_rollout_transition_id IS NULL AND actor_user_id IS NULL AND actor_role_snapshot IS NULL OR event_type::text = 'initial_launch'::text AND from_cohort_release_id IS NULL AND cohort_rollout_id IS NULL AND cohort_rollout_transition_id IS NULL AND actor_user_id IS NOT NULL AND actor_role_snapshot IS NOT NULL AND (actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying, 'owner'::character varying, 'reviewer'::character varying]::text[])) OR event_type::text = 'rollout_completed'::text AND cohort_rollout_id IS NOT NULL AND cohort_rollout_transition_id IS NOT NULL AND actor_user_id IS NOT NULL AND actor_role_snapshot IS NOT NULL AND (actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying, 'owner'::character varying, 'reviewer'::character varying]::text[]))", name: "release_activation_events_shape"
    t.check_constraint "event_type::text = ANY (ARRAY['backfill'::character varying, 'initial_launch'::character varying, 'rollout_completed'::character varying]::text[])", name: "release_activation_events_type_valid"
    t.check_constraint "request_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100", name: "release_activation_events_request_valid"
  end

  create_table "cohort_release_exposures", force: :cascade do |t|
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.bigint "cohort_membership_id", null: false
    t.bigint "cohort_release_id", null: false
    t.bigint "cohort_rollout_id"
    t.bigint "cohort_rollout_transition_id"
    t.bigint "cohort_rollout_wave_id"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "exposure_key", null: false
    t.datetime "membership_started_at", null: false
    t.datetime "occurred_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["coach_workspace_id"], name: "index_cohort_release_exposures_on_coach_workspace_id"
    t.index ["cohort_id", "exposure_key"], name: "idx_cohort_release_exposures_key", unique: true
    t.index ["cohort_id", "user_id", "cohort_membership_id", "membership_started_at", "occurred_at", "id"], name: "idx_cohort_release_exposures_runtime"
    t.index ["cohort_id"], name: "index_cohort_release_exposures_on_cohort_id"
    t.index ["cohort_release_id"], name: "index_cohort_release_exposures_on_cohort_release_id"
    t.index ["cohort_rollout_id", "cohort_rollout_transition_id", "user_id"], name: "idx_cohort_release_exposures_transition_user", unique: true, where: "(cohort_rollout_transition_id IS NOT NULL)"
    t.index ["cohort_rollout_id"], name: "index_cohort_release_exposures_on_cohort_rollout_id"
    t.index ["cohort_rollout_transition_id"], name: "index_cohort_release_exposures_on_cohort_rollout_transition_id"
    t.index ["cohort_rollout_wave_id"], name: "index_cohort_release_exposures_on_cohort_rollout_wave_id"
    t.index ["id", "cohort_id", "coach_workspace_id"], name: "idx_cohort_release_exposures_scope", unique: true
    t.index ["user_id"], name: "index_cohort_release_exposures_on_user_id"
    t.check_constraint "char_length(exposure_key::text) >= 1 AND char_length(exposure_key::text) <= 160", name: "cohort_release_exposures_key_bounded"
    t.check_constraint "cohort_rollout_id IS NOT NULL AND cohort_rollout_wave_id IS NOT NULL AND cohort_rollout_transition_id IS NOT NULL", name: "cohort_release_exposures_rollout_shape"
    t.check_constraint "event_type::text = ANY (ARRAY['wave'::character varying, 'rollback'::character varying]::text[])", name: "cohort_release_exposures_type_valid"
  end

  create_table "cohort_releases", force: :cascade do |t|
    t.string "actor_role_snapshot"
    t.string "brand_mode"
    t.jsonb "brand_snapshot"
    t.string "brand_snapshot_digest"
    t.jsonb "bundle", default: {}, null: false
    t.string "bundle_digest", null: false
    t.bigint "coach_persona_id"
    t.bigint "coach_persona_version_id"
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_experience_configuration_id", null: false
    t.bigint "cohort_experience_version_id"
    t.bigint "cohort_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "experience_mode", null: false
    t.jsonb "experience_snapshot", default: {}, null: false
    t.string "experience_snapshot_digest", null: false
    t.jsonb "manifest", default: {}, null: false
    t.string "manifest_digest", null: false
    t.string "manifest_schema", null: false
    t.string "persona_mode", null: false
    t.jsonb "persona_snapshot", default: {}, null: false
    t.string "persona_snapshot_digest", null: false
    t.string "publication_source", null: false
    t.integer "release_number", null: false
    t.datetime "released_at", null: false
    t.bigint "released_by_user_id"
    t.string "request_fingerprint", null: false
    t.string "request_key", null: false
    t.bigint "source_release_id"
    t.string "tool_registry_digest", null: false
    t.jsonb "tool_registry_snapshot", default: {}, null: false
    t.integer "tool_registry_version", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_brand_version_id"
    t.index ["coach_persona_id"], name: "index_cohort_releases_on_coach_persona_id"
    t.index ["coach_persona_version_id"], name: "index_cohort_releases_on_coach_persona_version_id"
    t.index ["coach_workspace_id"], name: "index_cohort_releases_on_coach_workspace_id"
    t.index ["cohort_experience_configuration_id"], name: "idx_cohort_releases_experience_configuration"
    t.index ["cohort_experience_version_id"], name: "idx_cohort_releases_experience_version"
    t.index ["cohort_id", "release_number"], name: "idx_cohort_releases_number", unique: true
    t.index ["cohort_id", "released_at", "id"], name: "idx_cohort_releases_history"
    t.index ["cohort_id", "request_key"], name: "idx_cohort_releases_request_key", unique: true
    t.index ["cohort_id"], name: "index_cohort_releases_on_cohort_id"
    t.index ["id", "cohort_id", "coach_workspace_id"], name: "idx_cohort_releases_id_cohort_workspace", unique: true
    t.index ["id", "cohort_id"], name: "idx_cohort_releases_id_cohort", unique: true
    t.index ["id", "released_by_user_id", "actor_role_snapshot"], name: "idx_cohort_releases_operation_actor", unique: true
    t.index ["released_by_user_id"], name: "index_cohort_releases_on_released_by_user_id"
    t.index ["source_release_id"], name: "index_cohort_releases_on_source_release_id"
    t.index ["workspace_brand_version_id"], name: "idx_cohort_releases_brand_version"
    t.check_constraint "(experience_mode::text = ANY (ARRAY['published_version'::character varying, 'safe_default'::character varying]::text[])) AND (experience_mode::text = 'published_version'::text AND cohort_experience_version_id IS NOT NULL OR experience_mode::text = 'safe_default'::text AND cohort_experience_version_id IS NULL)", name: "cohort_releases_experience_shape"
    t.check_constraint "(persona_mode::text = ANY (ARRAY['published_version'::character varying, 'neutral_builtin'::character varying]::text[])) AND (persona_mode::text = 'published_version'::text AND coach_persona_id IS NOT NULL AND coach_persona_version_id IS NOT NULL OR persona_mode::text = 'neutral_builtin'::text AND coach_persona_id IS NULL AND coach_persona_version_id IS NULL)", name: "cohort_releases_persona_shape"
    t.check_constraint "brand_snapshot IS NULL OR jsonb_typeof(brand_snapshot) = 'object'::text", name: "cohort_releases_brand_json_shape"
    t.check_constraint "brand_snapshot IS NULL OR octet_length(brand_snapshot::text) <= 32768", name: "cohort_releases_brand_json_bounded"
    t.check_constraint "brand_snapshot_digest IS NULL OR brand_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text", name: "cohort_releases_brand_digest_shape"
    t.check_constraint "char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100", name: "cohort_releases_request_key_bounded"
    t.check_constraint "event_type::text = 'restore'::text AND source_release_id IS NOT NULL OR (event_type::text = ANY (ARRAY['release'::character varying, 'reconciliation'::character varying]::text[])) AND source_release_id IS NULL", name: "cohort_releases_source_shape"
    t.check_constraint "event_type::text = ANY (ARRAY['release'::character varying, 'restore'::character varying, 'reconciliation'::character varying]::text[])", name: "cohort_releases_event_type_valid"
    t.check_constraint "jsonb_typeof(persona_snapshot) = 'object'::text AND jsonb_typeof(experience_snapshot) = 'object'::text AND jsonb_typeof(tool_registry_snapshot) = 'object'::text AND jsonb_typeof(bundle) = 'object'::text AND jsonb_typeof(manifest) = 'object'::text", name: "cohort_releases_json_shape"
    t.check_constraint "manifest_schema::text = 'cohort_release_manifest_v1'::text AND brand_mode IS NULL AND workspace_brand_version_id IS NULL AND brand_snapshot IS NULL AND brand_snapshot_digest IS NULL OR manifest_schema::text = 'cohort_release_manifest_v2'::text AND brand_snapshot IS NOT NULL AND brand_snapshot_digest IS NOT NULL AND (brand_mode::text = 'published_version'::text AND workspace_brand_version_id IS NOT NULL OR brand_mode::text = 'legacy_household_cfo_builtin'::text AND workspace_brand_version_id IS NULL)", name: "cohort_releases_brand_shape"
    t.check_constraint "manifest_schema::text = ANY (ARRAY['cohort_release_manifest_v1'::character varying, 'cohort_release_manifest_v2'::character varying]::text[])", name: "cohort_releases_manifest_schema_valid"
    t.check_constraint "octet_length(persona_snapshot::text) <= 65536 AND octet_length(experience_snapshot::text) <= 16384 AND octet_length(tool_registry_snapshot::text) <= 65536 AND octet_length(bundle::text) <= 196608 AND octet_length(manifest::text) <= 262144", name: "cohort_releases_json_bounded"
    t.check_constraint "persona_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND experience_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND tool_registry_digest::text ~ '^[0-9a-f]{64}$'::text AND bundle_digest::text ~ '^[0-9a-f]{64}$'::text AND manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND request_fingerprint::text ~ '^[0-9a-f]{64}$'::text", name: "cohort_releases_digest_shape"
    t.check_constraint "publication_source::text = 'user'::text AND released_by_user_id IS NOT NULL AND (actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying, 'owner'::character varying, 'reviewer'::character varying]::text[])) OR (publication_source::text = ANY (ARRAY['legacy_backfill'::character varying, 'system'::character varying]::text[])) AND released_by_user_id IS NULL AND actor_role_snapshot IS NULL", name: "cohort_releases_actor_shape"
    t.check_constraint "publication_source::text = ANY (ARRAY['user'::character varying, 'legacy_backfill'::character varying, 'system'::character varying]::text[])", name: "cohort_releases_publication_source_valid"
    t.check_constraint "release_number > 0 AND tool_registry_version > 0", name: "cohort_releases_positive_versions"
  end

  create_table "cohort_rollout_participants", force: :cascade do |t|
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.bigint "cohort_membership_id"
    t.bigint "cohort_rollout_id", null: false
    t.bigint "cohort_rollout_wave_id", null: false
    t.datetime "created_at", null: false
    t.datetime "membership_started_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["coach_workspace_id"], name: "index_cohort_rollout_participants_on_coach_workspace_id"
    t.index ["cohort_id"], name: "index_cohort_rollout_participants_on_cohort_id"
    t.index ["cohort_membership_id", "membership_started_at"], name: "idx_rollout_participants_membership_epoch"
    t.index ["cohort_rollout_id", "cohort_rollout_wave_id"], name: "idx_rollout_participants_wave"
    t.index ["cohort_rollout_id", "user_id"], name: "idx_rollout_participants_user", unique: true
    t.index ["cohort_rollout_id"], name: "index_cohort_rollout_participants_on_cohort_rollout_id"
    t.index ["cohort_rollout_wave_id"], name: "index_cohort_rollout_participants_on_cohort_rollout_wave_id"
    t.index ["id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], name: "idx_rollout_participants_scope", unique: true
    t.index ["user_id"], name: "index_cohort_rollout_participants_on_user_id"
    t.check_constraint "cohort_membership_id IS NULL AND membership_started_at IS NULL OR cohort_membership_id IS NOT NULL AND membership_started_at IS NOT NULL", name: "cohort_rollout_participants_membership_epoch_complete"
  end

  create_table "cohort_rollout_transitions", force: :cascade do |t|
    t.string "actor_role_snapshot", null: false
    t.bigint "actor_user_id", null: false
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.bigint "cohort_rollout_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "from_status"
    t.integer "from_wave_position"
    t.datetime "occurred_at", null: false
    t.boolean "participant_runtime_changed", default: false, null: false
    t.string "readiness_digest"
    t.bigint "rollback_cohort_release_id"
    t.string "to_status", null: false
    t.integer "to_wave_position"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_cohort_rollout_transitions_on_actor_user_id"
    t.index ["coach_workspace_id"], name: "index_cohort_rollout_transitions_on_coach_workspace_id"
    t.index ["cohort_id"], name: "index_cohort_rollout_transitions_on_cohort_id"
    t.index ["cohort_rollout_id", "id"], name: "idx_rollout_transitions_canonical_order"
    t.index ["cohort_rollout_id", "occurred_at", "id"], name: "idx_rollout_transitions_history"
    t.index ["cohort_rollout_id"], name: "index_cohort_rollout_transitions_on_cohort_rollout_id"
    t.index ["id", "actor_user_id", "actor_role_snapshot"], name: "idx_rollout_transitions_actor", unique: true
    t.index ["id", "cohort_id", "coach_workspace_id"], name: "idx_rollout_transitions_scope", unique: true
    t.index ["id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], name: "idx_rollout_transitions_full_scope", unique: true
    t.index ["rollback_cohort_release_id"], name: "idx_rollout_transitions_rollback_release"
    t.check_constraint "(event_type::text = ANY (ARRAY['activated'::character varying, 'advanced'::character varying, 'completed'::character varying, 'rolled_back'::character varying]::text[])) OR participant_runtime_changed = false", name: "cohort_rollout_transitions_runtime_changed_shape"
    t.check_constraint "(event_type::text = ANY (ARRAY['activated'::character varying, 'advanced'::character varying, 'completed'::character varying]::text[])) AND readiness_digest::text ~ '^[0-9a-f]{64}$'::text OR (event_type::text <> ALL (ARRAY['activated'::character varying, 'advanced'::character varying, 'completed'::character varying]::text[])) AND readiness_digest IS NULL", name: "cohort_rollout_transitions_readiness_evidence"
    t.check_constraint "(from_wave_position IS NULL OR from_wave_position >= 0 AND from_wave_position <= 25) AND (to_wave_position IS NULL OR to_wave_position >= 0 AND to_wave_position <= 25)", name: "cohort_rollout_transitions_wave_positions_bounded"
    t.check_constraint "(to_status::text = ANY (ARRAY['planned'::character varying, 'active'::character varying, 'paused'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'rolled_back'::character varying]::text[])) AND (from_status IS NULL OR (from_status::text = ANY (ARRAY['planned'::character varying, 'active'::character varying, 'paused'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'rolled_back'::character varying]::text[])))", name: "cohort_rollout_transitions_status_valid"
    t.check_constraint "actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying, 'owner'::character varying, 'reviewer'::character varying]::text[])", name: "cohort_rollout_transitions_actor_role_valid"
    t.check_constraint "event_type::text = 'planned'::text AND from_status IS NULL AND to_status::text = 'planned'::text AND from_wave_position IS NULL AND to_wave_position = 0 OR event_type::text = 'activated'::text AND from_status::text = 'planned'::text AND to_status::text = 'active'::text AND from_wave_position = 0 AND to_wave_position = 1 OR event_type::text = 'advanced'::text AND from_status::text = 'active'::text AND to_status::text = 'active'::text AND from_wave_position >= 1 AND to_wave_position = (from_wave_position + 1) OR event_type::text = 'completed'::text AND from_status::text = 'active'::text AND to_status::text = 'completed'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position OR event_type::text = 'paused'::text AND from_status::text = 'active'::text AND to_status::text = 'paused'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position OR event_type::text = 'resumed'::text AND from_status::text = 'paused'::text AND to_status::text = 'active'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position OR event_type::text = 'cancelled'::text AND from_status::text = 'planned'::text AND to_status::text = 'cancelled'::text AND from_wave_position = 0 AND to_wave_position = 0 OR event_type::text = 'rolled_back'::text AND (from_status::text = ANY (ARRAY['active'::character varying, 'paused'::character varying]::text[])) AND to_status::text = 'rolled_back'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position", name: "cohort_rollout_transitions_event_shape"
    t.check_constraint "event_type::text = 'rolled_back'::text AND rollback_cohort_release_id IS NOT NULL OR event_type::text <> 'rolled_back'::text AND rollback_cohort_release_id IS NULL", name: "cohort_rollout_transitions_rollback_shape"
    t.check_constraint "event_type::text = ANY (ARRAY['planned'::character varying, 'activated'::character varying, 'advanced'::character varying, 'paused'::character varying, 'resumed'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'rolled_back'::character varying]::text[])", name: "cohort_rollout_transitions_event_valid"
  end

  create_table "cohort_rollout_waves", force: :cascade do |t|
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.bigint "cohort_rollout_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_workspace_id"], name: "index_cohort_rollout_waves_on_coach_workspace_id"
    t.index ["cohort_id"], name: "index_cohort_rollout_waves_on_cohort_id"
    t.index ["cohort_rollout_id", "position"], name: "idx_cohort_rollout_waves_position", unique: true
    t.index ["cohort_rollout_id"], name: "index_cohort_rollout_waves_on_cohort_rollout_id"
    t.index ["id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], name: "idx_rollout_waves_scope", unique: true
    t.check_constraint "\"position\" >= 1 AND \"position\" <= 25", name: "cohort_rollout_waves_position_bounded"
    t.check_constraint "char_length(name::text) >= 1 AND char_length(name::text) <= 80", name: "cohort_rollout_waves_name_bounded"
  end

  create_table "cohort_rollouts", force: :cascade do |t|
    t.datetime "activated_at"
    t.bigint "baseline_cohort_release_id"
    t.datetime "cancelled_at"
    t.bigint "coach_workspace_id", null: false
    t.bigint "cohort_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "current_wave_position", default: 0, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "paused_at"
    t.datetime "planned_at", null: false
    t.string "planned_by_role_snapshot", null: false
    t.bigint "planned_by_user_id", null: false
    t.bigint "rollback_cohort_release_id"
    t.datetime "rolled_back_at"
    t.string "status", default: "planned", null: false
    t.bigint "target_cohort_release_id", null: false
    t.datetime "updated_at", null: false
    t.index ["baseline_cohort_release_id"], name: "index_cohort_rollouts_on_baseline_cohort_release_id"
    t.index ["coach_workspace_id"], name: "index_cohort_rollouts_on_coach_workspace_id"
    t.index ["cohort_id", "created_at", "id"], name: "idx_cohort_rollouts_history"
    t.index ["cohort_id"], name: "idx_cohort_rollouts_one_open", unique: true, where: "((status)::text = ANY (ARRAY[('planned'::character varying)::text, ('active'::character varying)::text, ('paused'::character varying)::text]))"
    t.index ["cohort_id"], name: "index_cohort_rollouts_on_cohort_id"
    t.index ["id", "cohort_id", "coach_workspace_id"], name: "idx_cohort_rollouts_id_cohort_workspace", unique: true
    t.index ["planned_by_user_id"], name: "index_cohort_rollouts_on_planned_by_user_id"
    t.index ["rollback_cohort_release_id"], name: "idx_cohort_rollouts_rollback_release"
    t.index ["target_cohort_release_id"], name: "idx_cohort_rollouts_target_release"
    t.check_constraint "baseline_cohort_release_id IS NULL OR baseline_cohort_release_id <> target_cohort_release_id", name: "cohort_rollouts_distinct_runtime_releases"
    t.check_constraint "current_wave_position >= 0 AND current_wave_position <= 25", name: "cohort_rollouts_wave_position_bounded"
    t.check_constraint "planned_by_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying, 'owner'::character varying, 'reviewer'::character varying]::text[])", name: "cohort_rollouts_actor_role_valid"
    t.check_constraint "status::text = 'planned'::text AND activated_at IS NULL AND paused_at IS NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'active'::text AND activated_at IS NOT NULL AND paused_at IS NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'paused'::text AND activated_at IS NOT NULL AND paused_at IS NOT NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'completed'::text AND activated_at IS NOT NULL AND paused_at IS NULL AND completed_at IS NOT NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'cancelled'::text AND activated_at IS NULL AND paused_at IS NULL AND completed_at IS NULL AND cancelled_at IS NOT NULL AND rolled_back_at IS NULL OR status::text = 'rolled_back'::text AND activated_at IS NOT NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NOT NULL", name: "cohort_rollouts_lifecycle_timestamps"
    t.check_constraint "status::text = 'rolled_back'::text AND rollback_cohort_release_id IS NOT NULL AND rolled_back_at IS NOT NULL OR status::text <> 'rolled_back'::text AND rollback_cohort_release_id IS NULL AND rolled_back_at IS NULL", name: "cohort_rollouts_rollback_shape"
    t.check_constraint "status::text = ANY (ARRAY['planned'::character varying, 'active'::character varying, 'paused'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'rolled_back'::character varying]::text[])", name: "cohort_rollouts_status_valid"
  end

  create_table "cohorts", force: :cascade do |t|
    t.bigint "active_cohort_release_id"
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.date "ends_on"
    t.string "name", null: false
    t.text "notes"
    t.integer "savings_challenge_capacity", default: 30, null: false
    t.boolean "savings_challenge_enabled", default: false, null: false
    t.string "savings_challenge_policy_version", default: "1", null: false
    t.boolean "savings_challenge_release_hold", default: true, null: false
    t.date "starts_on"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index "coach_workspace_id, lower((name)::text)", name: "index_cohorts_on_workspace_and_lower_name", unique: true
    t.index ["active_cohort_release_id"], name: "index_cohorts_on_active_cohort_release_id"
    t.index ["coach_workspace_id"], name: "index_cohorts_on_coach_workspace_id"
    t.index ["created_by_user_id"], name: "index_cohorts_on_created_by_user_id"
    t.index ["id", "coach_workspace_id", "active_cohort_release_id"], name: "idx_cohorts_active_release_scope", unique: true
    t.index ["id", "coach_workspace_id"], name: "idx_cohorts_id_workspace", unique: true
    t.index ["status"], name: "index_cohorts_on_status"
    t.check_constraint "savings_challenge_capacity >= 1 AND savings_challenge_capacity <= 30", name: "savings_challenge_capacity_valid"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'enrolling'::character varying, 'active'::character varying, 'completed'::character varying, 'archived'::character varying]::text[])", name: "cohorts_status_valid"
  end

  create_table "debts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.bigint "balance_cents", default: 0, null: false
    t.boolean "balance_known", default: true, null: false
    t.datetime "created_at", null: false
    t.string "debt_type", default: "other", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.decimal "interest_rate_percent", precision: 6, scale: 2
    t.string "label", null: false
    t.bigint "minimum_payment_cents", default: 0, null: false
    t.boolean "minimum_payment_known", default: true, null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.string "source_type", default: "manual_ui", null: false
    t.datetime "updated_at", null: false
    t.index "household_id, financial_generation, debt_type, lower((label)::text)", name: "index_active_debts_on_household_type_label", unique: true, where: "(active = true)"
    t.index ["household_id", "active"], name: "index_debts_on_household_id_and_active"
    t.index ["household_id", "debt_type"], name: "index_debts_on_household_id_and_debt_type"
    t.index ["household_id"], name: "index_debts_on_household_id"
    t.check_constraint "active = true AND archived_at IS NULL OR active = false AND archived_at IS NOT NULL", name: "debts_archive_state_valid"
    t.check_constraint "balance_cents >= 0", name: "debts_balance_cents_non_negative"
    t.check_constraint "minimum_payment_cents >= 0", name: "debts_minimum_payment_cents_non_negative"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_ui'::character varying, 'mia'::character varying, 'document_import'::character varying, 'setup'::character varying]::text[])", name: "debts_source_type_valid"
  end

  create_table "enterprise_audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id"
    t.datetime "created_at", null: false
    t.bigint "enterprise_organization_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_enterprise_audit_events_on_actor_user_id"
    t.index ["enterprise_organization_id"], name: "index_enterprise_audit_events_on_enterprise_organization_id"
  end

  create_table "enterprise_cohort_grants", force: :cascade do |t|
    t.bigint "cohort_membership_id", null: false
    t.datetime "created_at", null: false
    t.bigint "enterprise_membership_id", null: false
    t.datetime "updated_at", null: false
    t.index ["cohort_membership_id"], name: "enterprise_granted_enrollment_unique", unique: true
    t.index ["cohort_membership_id"], name: "index_enterprise_cohort_grants_on_cohort_membership_id"
    t.index ["enterprise_membership_id"], name: "index_enterprise_cohort_grants_on_enterprise_membership_id"
  end

  create_table "enterprise_directory_group_memberships", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.bigint "enterprise_directory_user_id", null: false
    t.datetime "provider_updated_at"
    t.datetime "updated_at", null: false
    t.string "workos_group_id", null: false
    t.index ["enterprise_directory_user_id", "workos_group_id"], name: "enterprise_directory_group_edge_unique", unique: true
    t.index ["enterprise_directory_user_id"], name: "idx_on_enterprise_directory_user_id_bc777cb581"
  end

  create_table "enterprise_directory_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.bigint "enterprise_membership_id"
    t.bigint "enterprise_organization_id", null: false
    t.datetime "provider_updated_at"
    t.string "state", default: "inactive", null: false
    t.datetime "updated_at", null: false
    t.string "workos_directory_user_id", null: false
    t.index ["enterprise_membership_id"], name: "index_enterprise_directory_users_on_enterprise_membership_id"
    t.index ["enterprise_organization_id"], name: "index_enterprise_directory_users_on_enterprise_organization_id"
    t.index ["workos_directory_user_id"], name: "index_enterprise_directory_users_on_workos_directory_user_id", unique: true
  end

  create_table "enterprise_group_mappings", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "cohort_id", null: false
    t.datetime "created_at", null: false
    t.bigint "enterprise_organization_id", null: false
    t.datetime "updated_at", null: false
    t.string "workos_group_id", null: false
    t.index ["cohort_id"], name: "index_enterprise_group_mappings_on_cohort_id"
    t.index ["enterprise_organization_id", "workos_group_id"], name: "enterprise_group_mapping_unique", unique: true
    t.index ["enterprise_organization_id"], name: "index_enterprise_group_mappings_on_enterprise_organization_id"
  end

  create_table "enterprise_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "enterprise_organization_id", null: false
    t.boolean "it_admin", default: false, null: false
    t.boolean "locally_revoked", default: false, null: false
    t.datetime "provider_updated_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "workos_membership_id"
    t.string "workos_user_id", null: false
    t.index ["enterprise_organization_id", "user_id"], name: "enterprise_membership_user_unique", unique: true
    t.index ["enterprise_organization_id", "workos_user_id"], name: "enterprise_membership_subject_unique", unique: true
    t.index ["enterprise_organization_id"], name: "index_enterprise_memberships_on_enterprise_organization_id"
    t.index ["user_id"], name: "index_enterprise_memberships_on_user_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'inactive'::character varying::text])", name: "enterprise_membership_status_valid"
  end

  create_table "enterprise_organizations", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "coach_workspace_id", null: false
    t.string "connection_state"
    t.datetime "created_at", null: false
    t.string "directory_id"
    t.boolean "directory_provisioning_enabled", default: false, null: false
    t.string "directory_state"
    t.datetime "last_reconciled_at"
    t.string "last_sync_error"
    t.string "name", null: false
    t.boolean "require_sso", default: true, null: false
    t.datetime "updated_at", null: false
    t.string "workos_organization_id", null: false
    t.index ["coach_workspace_id"], name: "index_enterprise_organizations_on_coach_workspace_id"
    t.index ["directory_id"], name: "index_enterprise_organizations_on_directory_id", unique: true
    t.index ["workos_organization_id"], name: "index_enterprise_organizations_on_workos_organization_id", unique: true
  end

  create_table "enterprise_sync_cursors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "cursor"
    t.string "last_error"
    t.datetime "last_polled_at"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_enterprise_sync_cursors_on_name", unique: true
  end

  create_table "enterprise_sync_events", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "last_error"
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.datetime "updated_at", null: false
    t.string "workos_event_id", null: false
    t.index ["processed_at"], name: "index_enterprise_sync_events_on_processed_at"
    t.index ["workos_event_id"], name: "index_enterprise_sync_events_on_workos_event_id", unique: true
  end

  create_table "expense_items", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "amount_cents", default: 0, null: false
    t.string "cadence", default: "monthly", null: false
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.string "stack_key", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "active"], name: "index_expense_items_on_household_id_and_active"
    t.index ["household_id", "financial_generation", "stack_key", "label"], name: "index_expense_items_on_household_stack_key_label", unique: true
    t.index ["household_id", "stack_key"], name: "index_expense_items_on_household_id_and_stack_key"
    t.index ["household_id"], name: "index_expense_items_on_household_id"
    t.check_constraint "amount_cents >= 0", name: "expense_items_amount_cents_non_negative"
  end

  create_table "financial_baseline_heads", force: :cascade do |t|
    t.bigint "approved_version_id"
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "participant_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "participant_user_id", "financial_generation"], name: "financial_baseline_participant_identity", unique: true
    t.index ["household_id"], name: "index_financial_baseline_heads_on_household_id"
    t.index ["id", "household_id"], name: "financial_baseline_head_household_identity", unique: true
    t.index ["id", "participant_user_id", "household_id"], name: "financial_baseline_head_actor_identity", unique: true
    t.index ["participant_user_id"], name: "index_financial_baseline_heads_on_participant_user_id"
  end

  create_table "financial_baseline_versions", force: :cascade do |t|
    t.bigint "approved_by_user_id", null: false
    t.string "calculation_version", null: false
    t.string "coverage_status", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.bigint "financial_baseline_head_id", null: false
    t.bigint "household_id", null: false
    t.text "reason", null: false
    t.jsonb "snapshot", null: false
    t.bigint "supersedes_id"
    t.integer "version_number", null: false
    t.date "window_end_on", null: false
    t.date "window_start_on", null: false
    t.index ["approved_by_user_id"], name: "index_financial_baseline_versions_on_approved_by_user_id"
    t.index ["financial_baseline_head_id", "version_number"], name: "financial_baseline_version_sequence", unique: true
    t.index ["financial_baseline_head_id"], name: "idx_on_financial_baseline_head_id_a1412e8b08"
    t.index ["household_id"], name: "index_financial_baseline_versions_on_household_id"
    t.index ["id", "financial_baseline_head_id", "household_id"], name: "financial_baseline_version_head_identity", unique: true
    t.check_constraint "coverage_status::text = ANY (ARRAY['complete'::character varying, 'partial'::character varying, 'manual'::character varying]::text[])", name: "financial_baseline_coverage_status"
    t.check_constraint "window_end_on >= window_start_on AND version_number > 0", name: "financial_baseline_window_version"
  end

  create_table "financial_document_extraction_dispatches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "enqueue_attempts", default: 0, null: false
    t.string "error_code"
    t.bigint "financial_document_import_id"
    t.bigint "generation", default: 1, null: false
    t.datetime "lease_expires_at"
    t.string "lease_token"
    t.datetime "next_attempt_at", null: false
    t.string "source_fingerprint", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["financial_document_import_id"], name: "idx_on_financial_document_import_id_d46e018bd2", unique: true
    t.index ["status", "next_attempt_at"], name: "index_extraction_dispatches_recovery"
    t.check_constraint "(status::text <> ALL (ARRAY['enqueued'::character varying, 'processing'::character varying]::text[])) OR lease_expires_at IS NOT NULL", name: "extraction_dispatch_active_lease"
    t.check_constraint "generation > 0 AND enqueue_attempts >= 0", name: "extraction_dispatch_counters"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'enqueued'::character varying, 'processing'::character varying, 'completed'::character varying, 'cancelled'::character varying]::text[])", name: "extraction_dispatch_status"
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
    t.decimal "interest_rate_percent", precision: 6, scale: 2
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
    t.check_constraint "NOT (selected AND ignored)", name: "financial_document_import_items_selected_not_ignored"
    t.check_constraint "amount_cents IS NULL OR amount_cents >= 0", name: "financial_doc_items_amount_cents_non_negative"
    t.check_constraint "balance_cents IS NULL OR balance_cents >= 0 OR target_type::text = 'account'::text AND (account_type::text = ANY (ARRAY['checking'::character varying, 'savings'::character varying]::text[]))", name: "financial_doc_items_balance_cents_valid"
    t.check_constraint "confidence IS NULL OR (confidence::text = ANY (ARRAY['high'::character varying, 'medium'::character varying, 'low'::character varying]::text[]))", name: "financial_document_import_items_confidence_valid"
    t.check_constraint "interest_rate_percent IS NULL OR interest_rate_percent >= 0::numeric AND interest_rate_percent <= 999.99", name: "financial_doc_items_apr_valid"
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
    t.integer "financial_generation", default: 0, null: false
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
    t.index ["s3_key"], name: "index_financial_document_imports_on_s3_key", unique: true, where: "(s3_key IS NOT NULL)"
    t.index ["source_deleted_by_user_id"], name: "index_financial_document_imports_on_source_deleted_by_user_id"
    t.index ["uploaded_by_user_id"], name: "index_financial_document_imports_on_uploaded_by_user_id"
    t.check_constraint "byte_size >= 0", name: "financial_document_imports_byte_size_non_negative"
    t.check_constraint "document_kind::text = ANY (ARRAY['spreadsheet'::character varying, 'statement'::character varying, 'pay_stub'::character varying, 'receipt'::character varying, 'other'::character varying]::text[])", name: "financial_document_imports_document_kind_valid"
    t.check_constraint "status::text = ANY (ARRAY['uploaded'::character varying, 'processing'::character varying, 'needs_review'::character varying, 'applied'::character varying, 'partially_applied'::character varying, 'failed'::character varying, 'source_deleted'::character varying]::text[])", name: "financial_document_imports_status_valid"
  end

  create_table "financial_document_source_cleanups", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "error_code"
    t.bigint "financial_document_import_id"
    t.bigint "household_id"
    t.datetime "lease_expires_at"
    t.string "lease_token"
    t.datetime "next_attempt_at", null: false
    t.bigint "requested_by_user_id"
    t.string "s3_key", limit: 1024
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["financial_document_import_id"], name: "idx_document_cleanup_import"
    t.index ["household_id"], name: "index_financial_document_source_cleanups_on_household_id"
    t.index ["requested_by_user_id"], name: "idx_on_requested_by_user_id_961d281d8f"
    t.index ["s3_key"], name: "idx_document_cleanup_key", unique: true
    t.index ["status", "next_attempt_at"], name: "idx_document_cleanup_due"
    t.check_constraint "attempts >= 0", name: "document_cleanup_attempts_nonnegative"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processing'::character varying, 'failed'::character varying, 'completed'::character varying]::text[])", name: "document_cleanup_status_valid"
  end

  create_table "financial_extraction_revisions", force: :cascade do |t|
    t.string "contract_version", null: false
    t.jsonb "coverage", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "financial_document_import_attempt_id"
    t.bigint "financial_document_import_id"
    t.bigint "household_id", null: false
    t.string "payload_digest", null: false
    t.jsonb "reconciliation", default: {}, null: false
    t.integer "revision_number", null: false
    t.string "source_document_identity", null: false
    t.index ["financial_document_import_attempt_id"], name: "index_extraction_revisions_unique_attempt", unique: true
    t.index ["financial_document_import_id", "revision_number"], name: "index_extraction_revisions_import_number", unique: true
    t.index ["financial_document_import_id"], name: "idx_on_financial_document_import_id_0c4473f699"
    t.index ["household_id"], name: "index_financial_extraction_revisions_on_household_id"
    t.index ["id", "household_id"], name: "index_extraction_revisions_household_identity", unique: true
  end

  create_table "financial_restart_reviews", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "cohort_id"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.integer "financial_generation", null: false
    t.bigint "household_id", null: false
    t.jsonb "inventory", default: {}, null: false
    t.string "inventory_fingerprint", null: false
    t.jsonb "previous_setup", default: {}, null: false
    t.string "purpose", default: "admin_test", null: false
    t.bigint "requested_by_user_id", null: false
    t.integer "result_generation"
    t.bigint "setup_support_request_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["cohort_id"], name: "index_financial_restart_reviews_on_cohort_id"
    t.index ["household_id"], name: "index_financial_restart_reviews_on_household_id"
    t.index ["requested_by_user_id"], name: "index_financial_restart_reviews_on_requested_by_user_id"
    t.index ["setup_support_request_id"], name: "index_financial_restart_reviews_on_setup_support_request_id"
    t.check_constraint "purpose::text = ANY (ARRAY['admin_test'::character varying, 'self_setup'::character varying, 'supported_setup'::character varying]::text[])", name: "financial_restart_purpose"
  end

  create_table "financial_source_accounts", force: :cascade do |t|
    t.string "account_basis", default: "unknown", null: false
    t.bigint "closing_balance_cents"
    t.datetime "created_at", null: false
    t.bigint "financial_extraction_revision_id", null: false
    t.bigint "household_id", null: false
    t.jsonb "limitations", default: [], null: false
    t.bigint "opening_balance_cents"
    t.date "period_end_on"
    t.date "period_start_on"
    t.bigint "printed_credit_cents"
    t.bigint "printed_debit_cents"
    t.integer "printed_row_count"
    t.string "source_key", null: false
    t.index ["financial_extraction_revision_id", "source_key"], name: "index_source_accounts_revision_key", unique: true
    t.index ["financial_extraction_revision_id"], name: "index_source_accounts_revision"
    t.index ["household_id"], name: "index_financial_source_accounts_on_household_id"
    t.index ["id", "financial_extraction_revision_id", "household_id"], name: "index_source_accounts_scoped_identity", unique: true
    t.index ["id", "household_id"], name: "index_source_accounts_household_identity", unique: true
    t.check_constraint "account_basis::text = ANY (ARRAY['asset'::character varying, 'liability'::character varying, 'unknown'::character varying]::text[])", name: "source_account_basis_valid"
  end

  create_table "financial_source_events", force: :cascade do |t|
    t.date "authorized_on"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "expense_amount_cents"
    t.bigint "financial_extraction_revision_id", null: false
    t.bigint "financial_source_account_id", null: false
    t.jsonb "funding_components", default: [], null: false
    t.bigint "household_id", null: false
    t.jsonb "limitations", default: [], null: false
    t.jsonb "locator", default: {}, null: false
    t.integer "position", null: false
    t.date "posted_on"
    t.string "row_identity", null: false
    t.string "row_kind", null: false
    t.bigint "signed_amount_cents"
    t.index ["financial_extraction_revision_id", "position"], name: "index_source_events_revision_position", unique: true
    t.index ["financial_extraction_revision_id", "row_identity"], name: "index_source_events_revision_row", unique: true
    t.index ["financial_extraction_revision_id"], name: "index_source_events_revision"
    t.index ["financial_source_account_id"], name: "index_financial_source_events_on_financial_source_account_id"
    t.index ["household_id"], name: "index_financial_source_events_on_household_id"
    t.index ["id", "household_id"], name: "index_source_events_household_identity", unique: true
    t.check_constraint "event_type::text = ANY (ARRAY['purchase'::character varying, 'fee'::character varying, 'refund'::character varying, 'income'::character varying, 'transfer'::character varying, 'debt_payment'::character varying, 'cash_withdrawal'::character varying, 'interest'::character varying, 'adjustment'::character varying, 'unknown'::character varying]::text[])", name: "source_event_type_valid"
    t.check_constraint "expense_amount_cents IS NULL OR expense_amount_cents > 0", name: "source_event_expense_positive"
    t.check_constraint "expense_amount_cents IS NULL OR row_kind::text = 'posted'::text AND (event_type::text = ANY (ARRAY['purchase'::character varying, 'fee'::character varying, 'interest'::character varying]::text[])) AND signed_amount_cents < 0 AND posted_on IS NOT NULL", name: "source_event_expense_eligible"
    t.check_constraint "row_kind::text = ANY (ARRAY['posted'::character varying, 'informational'::character varying, 'unresolved'::character varying]::text[])", name: "source_event_kind_valid"
  end

  create_table "financial_source_evidences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "financial_source_account_id"
    t.bigint "financial_source_event_id"
    t.bigint "household_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["financial_source_account_id"], name: "idx_on_financial_source_account_id_9c82150f7f", unique: true
    t.index ["financial_source_event_id"], name: "index_financial_source_evidences_on_financial_source_event_id", unique: true
    t.index ["household_id"], name: "index_financial_source_evidences_on_household_id"
    t.check_constraint "num_nonnulls(financial_source_account_id, financial_source_event_id) = 1", name: "source_evidence_one_subject"
  end

  create_table "financial_source_uses", force: :cascade do |t|
    t.datetime "authorized_at", null: false
    t.datetime "created_at", null: false
    t.string "disclosure_version", null: false
    t.datetime "expires_at", null: false
    t.bigint "financial_document_import_id"
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "participant_user_id", null: false
    t.datetime "revoked_at"
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["financial_document_import_id", "savings_enrollment_id"], name: "financial_source_use_identity", unique: true
    t.index ["financial_document_import_id"], name: "index_financial_source_uses_on_financial_document_import_id"
    t.index ["household_id"], name: "index_financial_source_uses_on_household_id"
    t.index ["participant_user_id"], name: "index_financial_source_uses_on_participant_user_id"
    t.index ["savings_enrollment_id"], name: "index_financial_source_uses_on_savings_enrollment_id"
  end

  create_table "goals", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.integer "current_amount_cents", default: 0, null: false
    t.boolean "current_amount_known", default: false, null: false
    t.integer "financial_generation", default: 0, null: false
    t.string "goal_type", default: "other", null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.integer "priority", default: 0, null: false
    t.string "record_kind", default: "tracked", null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.string "source_type", default: "manual_ui", null: false
    t.integer "target_amount_cents", default: 0, null: false
    t.boolean "target_amount_known", default: false, null: false
    t.decimal "target_months", precision: 6, scale: 2
    t.date "target_on"
    t.datetime "updated_at", null: false
    t.index "household_id, lower((label)::text), goal_type", name: "index_goals_on_active_tracked_identity", unique: true, where: "(((record_kind)::text = 'tracked'::text) AND (active = true))"
    t.index ["household_id", "active"], name: "index_goals_on_household_id_and_active"
    t.index ["household_id", "financial_generation"], name: "index_goals_on_one_runway_per_household", unique: true, where: "((goal_type)::text = 'runway'::text)"
    t.index ["household_id", "financial_generation"], name: "index_goals_on_one_transition_per_household", unique: true, where: "((goal_type)::text = 'transition'::text)"
    t.index ["household_id", "goal_type"], name: "index_goals_on_household_id_and_goal_type"
    t.index ["household_id", "priority"], name: "index_goals_on_household_id_and_priority"
    t.index ["household_id", "record_kind", "priority"], name: "index_goals_on_kind_and_priority"
    t.index ["household_id"], name: "index_goals_on_household_id"
    t.check_constraint "active = true AND archived_at IS NULL OR active = false AND archived_at IS NOT NULL", name: "goals_archive_state_valid"
    t.check_constraint "current_amount_cents >= 0", name: "goals_current_amount_cents_non_negative"
    t.check_constraint "current_amount_known = true OR current_amount_cents = 0", name: "goals_unknown_current_is_zero"
    t.check_constraint "jsonb_typeof(source_metadata) = 'object'::text", name: "goals_source_metadata_object"
    t.check_constraint "record_kind::text = ANY (ARRAY['tracked'::character varying, 'policy'::character varying]::text[])", name: "goals_record_kind_valid"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_ui'::character varying, 'mia'::character varying, 'document_import'::character varying, 'setup'::character varying]::text[])", name: "goals_source_type_valid"
    t.check_constraint "target_amount_cents >= 0", name: "goals_target_amount_cents_non_negative"
    t.check_constraint "target_amount_known = true OR target_amount_cents = 0", name: "goals_unknown_target_is_zero"
  end

  create_table "household_audit_events", force: :cascade do |t|
    t.string "actor_type", default: "user", null: false
    t.bigint "auditable_id"
    t.string "auditable_type"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "household_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["auditable_type", "auditable_id"], name: "index_household_audit_events_on_auditable"
    t.index ["household_id", "occurred_at"], name: "index_household_audit_events_on_household_occurred_at"
    t.index ["household_id"], name: "index_household_audit_events_on_household_id"
    t.index ["user_id"], name: "index_household_audit_events_on_user_id"
    t.check_constraint "actor_type::text = ANY (ARRAY['user'::character varying, 'mia'::character varying, 'system'::character varying]::text[])", name: "household_audit_events_actor_type_valid"
  end

  create_table "household_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.boolean "mia_personalization_paused", default: false, null: false
    t.datetime "mia_personalization_paused_at"
    t.string "role", default: "owner", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_id", "user_id"], name: "index_household_memberships_on_household_id_and_user_id", unique: true
    t.index ["household_id"], name: "index_household_memberships_on_household_id"
    t.index ["role"], name: "index_household_memberships_on_role"
    t.index ["user_id"], name: "index_household_memberships_on_one_owner_per_user", unique: true, where: "((role)::text = 'owner'::text)"
    t.index ["user_id"], name: "index_household_memberships_on_user_id"
  end

  create_table "household_memories", force: :cascade do |t|
    t.string "category", null: false
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "display_value", null: false
    t.datetime "expires_at"
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.bigint "owner_user_id", null: false
    t.datetime "rejected_at"
    t.string "request_key"
    t.string "sensitivity", default: "ordinary", null: false
    t.bigint "source_chat_message_id"
    t.string "source_kind", default: "manual_profile", null: false
    t.string "status", default: "pending_confirmation", null: false
    t.jsonb "structured_value", default: {}, null: false
    t.datetime "updated_at", null: false
    t.string "visibility", default: "private", null: false
    t.index ["household_id", "owner_user_id", "request_key"], name: "index_household_memories_on_request_key", unique: true, where: "(request_key IS NOT NULL)"
    t.index ["household_id", "status", "expires_at"], name: "index_household_memories_on_active_scope"
    t.index ["household_id"], name: "index_household_memories_on_household_id"
    t.index ["owner_user_id"], name: "index_household_memories_on_owner_user_id"
    t.index ["source_chat_message_id"], name: "index_household_memories_on_source_chat_message_id"
    t.check_constraint "category::text = ANY (ARRAY['goal'::character varying, 'preference'::character varying, 'constraint'::character varying, 'habit'::character varying, 'coaching_style'::character varying, 'follow_up'::character varying]::text[])", name: "household_memories_category_valid"
    t.check_constraint "char_length(display_value::text) >= 1 AND char_length(display_value::text) <= 500", name: "household_memories_display_value_length"
    t.check_constraint "request_key IS NULL OR char_length(request_key::text) <= 120", name: "household_memories_request_key_length"
    t.check_constraint "sensitivity::text = ANY (ARRAY['ordinary'::character varying, 'sensitive'::character varying]::text[])", name: "household_memories_sensitivity_valid"
    t.check_constraint "source_kind::text = ANY (ARRAY['manual_profile'::character varying, 'mia_command'::character varying]::text[])", name: "household_memories_source_kind_valid"
    t.check_constraint "status::text = ANY (ARRAY['pending_confirmation'::character varying, 'user_confirmed'::character varying, 'rejected'::character varying, 'expired'::character varying]::text[])", name: "household_memories_status_valid"
    t.check_constraint "visibility::text = 'private'::text", name: "household_memories_visibility_valid"
  end

  create_table "household_operation_executions", force: :cascade do |t|
    t.jsonb "after_snapshot", default: {}, null: false
    t.jsonb "before_snapshot", default: {}, null: false
    t.datetime "completed_at", null: false
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_audit_event_id", null: false
    t.bigint "household_id", null: false
    t.string "idempotency_key", null: false
    t.string "invocation_fingerprint"
    t.jsonb "normalized_input", default: {}, null: false
    t.string "operation_key", null: false
    t.integer "operation_version", null: false
    t.jsonb "predicted_after_snapshot", default: {}, null: false
    t.string "request_fingerprint", null: false
    t.bigint "reviewable_id"
    t.string "reviewable_type"
    t.string "source", null: false
    t.string "status", default: "completed", null: false
    t.bigint "subject_id"
    t.string "subject_type"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_audit_event_id"], name: "idx_on_household_audit_event_id_9da5b971f6"
    t.index ["household_id", "idempotency_key"], name: "index_household_operations_on_household_and_idempotency", unique: true
    t.index ["household_id"], name: "index_household_operation_executions_on_household_id"
    t.index ["reviewable_type", "reviewable_id"], name: "index_household_operation_executions_on_reviewable"
    t.index ["subject_type", "subject_id"], name: "index_household_operations_on_subject"
    t.index ["user_id"], name: "index_household_operation_executions_on_user_id"
    t.check_constraint "invocation_fingerprint IS NULL OR invocation_fingerprint::text ~ '^[0-9a-f]{64}$'::text", name: "household_operations_invocation_fingerprint_valid"
    t.check_constraint "jsonb_typeof(after_snapshot) = 'object'::text", name: "household_operations_after_object"
    t.check_constraint "jsonb_typeof(before_snapshot) = 'object'::text", name: "household_operations_before_object"
    t.check_constraint "jsonb_typeof(normalized_input) = 'object'::text", name: "household_operations_input_object"
    t.check_constraint "jsonb_typeof(predicted_after_snapshot) = 'object'::text", name: "household_operations_predicted_object"
    t.check_constraint "operation_version > 0", name: "household_operations_version_positive"
    t.check_constraint "source::text = ANY (ARRAY['manual'::character varying, 'mia'::character varying]::text[])", name: "household_operations_source_valid"
    t.check_constraint "status::text = 'completed'::text", name: "household_operations_status_valid"
  end

  create_table "household_profiles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "debt_summary_balance_cents", default: 0, null: false
    t.boolean "debt_summary_balance_known", default: false, null: false
    t.bigint "debt_summary_minimum_payment_cents", default: 0, null: false
    t.boolean "debt_summary_minimum_payment_known", default: false, null: false
    t.string "debt_tracking_mode", default: "individual", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.string "household_stage"
    t.integer "money_stress_level"
    t.text "notes"
    t.text "primary_decision"
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_household_profiles_on_household_id", unique: true
    t.check_constraint "debt_summary_balance_cents >= 0", name: "household_profiles_debt_summary_balance_non_negative"
    t.check_constraint "debt_summary_minimum_payment_cents >= 0", name: "household_profiles_debt_summary_minimum_non_negative"
    t.check_constraint "debt_tracking_mode::text = ANY (ARRAY['summary'::character varying, 'individual'::character varying]::text[])", name: "household_profiles_debt_tracking_mode_valid"
  end

  create_table "household_transactions", force: :cascade do |t|
    t.bigint "budget_period_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "financial_generation", default: 0, null: false
    t.bigint "financial_source_event_id"
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
    t.index ["financial_source_event_id"], name: "index_household_transactions_on_financial_source_event_id"
    t.index ["household_id", "occurred_on"], name: "index_household_transactions_on_household_id_and_occurred_on"
    t.index ["household_id", "status"], name: "index_household_transactions_on_household_id_and_status"
    t.index ["household_id"], name: "index_household_transactions_on_household_id"
    t.index ["id", "household_id"], name: "household_transactions_source_review_household_identity", unique: true
    t.index ["source_import_id"], name: "index_household_transactions_on_source_import_id"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_chat'::character varying, 'manual_ui'::character varying, 'receipt'::character varying, 'screenshot'::character varying, 'statement'::character varying, 'import'::character varying, 'plaid'::character varying]::text[])", name: "household_transactions_source_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['confirmed'::character varying, 'reconciled'::character varying, 'ignored'::character varying]::text[])", name: "household_transactions_status_valid"
    t.check_constraint "total_amount_cents > 0", name: "household_transactions_amount_positive"
  end

  create_table "households", force: :cascade do |t|
    t.jsonb "confirmed_setup_fields", default: [], null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.integer "financial_generation", default: 0, null: false
    t.string "location"
    t.string "name", null: false
    t.text "primary_goal"
    t.string "stage"
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_households_on_created_by_user_id"
    t.check_constraint "jsonb_typeof(confirmed_setup_fields) = 'array'::text", name: "households_confirmed_setup_fields_array"
  end

  create_table "income_schedule_entries", force: :cascade do |t|
    t.integer "amount_cents", default: 0, null: false
    t.string "cadence", default: "monthly", null: false
    t.datetime "created_at", null: false
    t.date "effective_on", null: false
    t.string "entry_type", default: "recurring_change", null: false
    t.bigint "income_source_id", null: false
    t.string "label"
    t.boolean "retained_after_transition"
    t.datetime "updated_at", null: false
    t.index ["income_source_id", "effective_on"], name: "index_income_schedule_entries_on_recurring_source_and_date", unique: true, where: "((entry_type)::text = 'recurring_change'::text)"
    t.index ["income_source_id"], name: "index_income_schedule_entries_on_income_source_id"
    t.check_constraint "amount_cents >= 0", name: "income_schedule_entries_amount_cents_non_negative"
    t.check_constraint "entry_type::text = ANY (ARRAY['recurring_change'::character varying, 'one_time'::character varying]::text[])", name: "income_schedule_entries_type_valid"
    t.check_constraint "retained_after_transition IS NOT TRUE OR entry_type::text = 'recurring_change'::text AND amount_cents > 0", name: "income_schedule_entries_retained_income_valid"
  end

  create_table "income_sources", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "amount_cents", default: 0, null: false
    t.string "cadence", default: "monthly", null: false
    t.datetime "created_at", null: false
    t.date "ends_on"
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.string "source_type", default: "other", null: false
    t.date "starts_on"
    t.datetime "updated_at", null: false
    t.index "household_id, financial_generation, source_type, lower((label)::text)", name: "index_income_sources_on_household_type_lower_label", unique: true, where: "(active = true)"
    t.index ["household_id", "active"], name: "index_income_sources_on_household_id_and_active"
    t.index ["household_id", "source_type"], name: "index_income_sources_on_household_id_and_source_type"
    t.index ["household_id"], name: "index_income_sources_on_household_id"
    t.check_constraint "amount_cents >= 0", name: "income_sources_amount_cents_non_negative"
    t.check_constraint "starts_on IS NULL OR ends_on IS NULL OR starts_on <= ends_on", name: "income_sources_temporal_bounds_valid"
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
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.datetime "last_confirmed_at"
    t.string "merchant_pattern", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "source", default: "user_confirmed", null: false
    t.integer "times_confirmed", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["budget_category_id"], name: "index_merchant_category_rules_on_budget_category_id"
    t.index ["household_id", "active", "merchant_pattern"], name: "index_merchant_rules_on_household_active_pattern"
    t.index ["household_id", "financial_generation", "merchant_pattern", "budget_category_id"], name: "index_merchant_rules_on_household_pattern_category", unique: true
    t.index ["household_id"], name: "index_merchant_category_rules_on_household_id"
    t.check_constraint "char_length(merchant_pattern::text) <= 120", name: "merchant_category_rules_pattern_length"
    t.check_constraint "confidence >= 0::numeric AND confidence <= 1::numeric", name: "merchant_category_rules_confidence_unit_interval"
    t.check_constraint "source::text = ANY (ARRAY['user_confirmed'::character varying, 'system_inferred'::character varying, 'coach_confirmed'::character varying]::text[])", name: "merchant_category_rules_source_valid"
    t.check_constraint "times_confirmed >= 0", name: "merchant_category_rules_times_confirmed_non_negative"
  end

  create_table "mia_action_draft_applications", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "idempotency_key", null: false
    t.bigint "mia_action_draft_id", null: false
    t.string "request_fingerprint", null: false
    t.string "request_kind", default: "apply", null: false
    t.jsonb "response_payload", default: {}, null: false
    t.jsonb "selected_item_ids", default: [], null: false
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_id", "user_id", "idempotency_key"], name: "index_mia_plan_applications_on_actor_and_key", unique: true
    t.index ["household_id"], name: "index_mia_action_draft_applications_on_household_id"
    t.index ["mia_action_draft_id"], name: "index_mia_action_draft_applications_on_mia_action_draft_id"
    t.index ["user_id"], name: "index_mia_action_draft_applications_on_user_id"
    t.check_constraint "char_length(idempotency_key::text) >= 1 AND char_length(idempotency_key::text) <= 200", name: "mia_plan_applications_key_length"
    t.check_constraint "jsonb_typeof(selected_item_ids) = 'array'::text", name: "mia_plan_applications_selected_ids_array"
    t.check_constraint "request_kind::text = ANY (ARRAY['apply'::character varying, 'cancel'::character varying]::text[])", name: "mia_plan_applications_request_kind_valid"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying, 'completed'::character varying, 'failed'::character varying]::text[])", name: "mia_plan_applications_status_valid"
  end

  create_table "mia_action_drafts", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_user_id"
    t.bigint "assistant_chat_message_id"
    t.datetime "canceled_at"
    t.bigint "canceled_by_user_id"
    t.datetime "created_at", null: false
    t.string "draft_type", default: "budget_edit", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "rationale"
    t.bigint "requested_by_user_id", null: false
    t.bigint "source_chat_message_id"
    t.text "source_prompt"
    t.string "status", default: "pending", null: false
    t.text "summary", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["applied_by_user_id"], name: "index_mia_action_drafts_on_applied_by_user_id"
    t.index ["assistant_chat_message_id"], name: "index_mia_action_drafts_on_assistant_chat_message_id"
    t.index ["canceled_by_user_id"], name: "index_mia_action_drafts_on_canceled_by_user_id"
    t.index ["household_id", "status", "year", "created_at"], name: "index_mia_action_drafts_on_household_status_year_created"
    t.index ["household_id"], name: "index_mia_action_drafts_on_household_id"
    t.index ["id", "household_id"], name: "index_mia_action_drafts_on_id_and_household", unique: true
    t.index ["requested_by_user_id"], name: "index_mia_action_drafts_on_requested_by_user_id"
    t.index ["source_chat_message_id"], name: "index_mia_action_drafts_on_source_chat_message_id"
    t.check_constraint "draft_type::text = ANY (ARRAY['budget_edit'::character varying, 'household_setup'::character varying, 'income_schedule'::character varying, 'debt_plan'::character varying, 'asset_plan'::character varying, 'goal_plan'::character varying, 'action_plan'::character varying]::text[])", name: "mia_action_drafts_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'partially_applied'::character varying, 'applied'::character varying, 'canceled'::character varying]::text[])", name: "mia_action_drafts_status_valid"
    t.check_constraint "year >= 2000 AND year <= 2100", name: "mia_action_drafts_year_reasonable"
  end

  create_table "mia_action_items", force: :cascade do |t|
    t.string "action_type", null: false
    t.jsonb "after_snapshot", default: {}, null: false
    t.datetime "applied_at"
    t.jsonb "before_snapshot", default: {}, null: false
    t.datetime "canceled_at"
    t.bigint "canceled_by_user_id"
    t.datetime "created_at", null: false
    t.jsonb "dependencies", default: [], null: false
    t.text "description"
    t.string "label", null: false
    t.bigint "mia_action_draft_id", null: false
    t.string "operation_key"
    t.integer "operation_version"
    t.jsonb "payload", default: {}, null: false
    t.integer "position", default: 0, null: false
    t.jsonb "prepared_operation", default: {}, null: false
    t.string "prepared_operation_fingerprint"
    t.integer "source_end"
    t.integer "source_start"
    t.text "source_text"
    t.bigint "target_record_id"
    t.string "target_record_type"
    t.datetime "updated_at", null: false
    t.index ["canceled_by_user_id"], name: "index_mia_action_items_on_canceled_by_user_id"
    t.index ["mia_action_draft_id", "position"], name: "index_mia_action_items_on_draft_position"
    t.index ["mia_action_draft_id"], name: "index_mia_action_items_on_mia_action_draft_id"
    t.index ["target_record_type", "target_record_id"], name: "index_mia_action_items_on_target"
    t.check_constraint "\"position\" >= 0", name: "mia_action_items_position_non_negative"
    t.check_constraint "action_type::text = ANY (ARRAY['create_category'::character varying, 'update_category'::character varying, 'update_allocation'::character varying, 'archive_category'::character varying, 'restore_category'::character varying, 'update_setup_value'::character varying, 'upsert_income_schedule_entry'::character varying, 'create_income_source'::character varying, 'update_income_source'::character varying, 'archive_income_source'::character varying, 'restore_income_source'::character varying, 'create_income_schedule_entry'::character varying, 'update_income_schedule_entry'::character varying, 'delete_income_schedule_entry'::character varying, 'create_debt'::character varying, 'update_debt'::character varying, 'archive_debt'::character varying, 'restore_debt'::character varying, 'update_debt_tracking'::character varying, 'create_account'::character varying, 'update_account'::character varying, 'archive_account'::character varying, 'restore_account'::character varying, 'link_plaid_account'::character varying, 'reconcile_plaid_account'::character varying, 'unlink_plaid_account'::character varying, 'create_goal'::character varying, 'update_goal'::character varying, 'archive_goal'::character varying, 'restore_goal'::character varying, 'update_runway_policy'::character varying, 'update_transition_policy'::character varying, 'update_household_profile'::character varying, 'confirm_household_setup'::character varying]::text[])", name: "mia_action_items_action_type_valid"
    t.check_constraint "jsonb_typeof(dependencies) = 'array'::text", name: "mia_action_items_dependencies_array"
    t.check_constraint "jsonb_typeof(prepared_operation) = 'object'::text", name: "mia_action_items_prepared_operation_object"
    t.check_constraint "operation_key IS NULL AND operation_version IS NULL AND prepared_operation_fingerprint IS NULL AND prepared_operation = '{}'::jsonb OR operation_key IS NOT NULL AND operation_version > 0 AND prepared_operation_fingerprint IS NOT NULL AND prepared_operation <> '{}'::jsonb", name: "mia_action_items_operation_identity_complete"
    t.check_constraint "source_start IS NULL AND source_end IS NULL OR source_start >= 0 AND source_end > source_start", name: "mia_action_items_source_span_valid"
  end

  create_table "mia_message_requests", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.string "request_fingerprint", null: false
    t.string "request_key", null: false
    t.jsonb "response_payload", default: {}, null: false
    t.integer "response_status"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "request_key"], name: "index_mia_message_requests_on_chat_session_id_and_request_key", unique: true
    t.index ["chat_session_id"], name: "index_mia_message_requests_on_chat_session_id"
    t.check_constraint "char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100", name: "mia_message_requests_key_length"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying, 'completed'::character varying, 'failed'::character varying]::text[])", name: "mia_message_requests_status_valid"
  end

  create_table "pilot_feedback_reports", force: :cascade do |t|
    t.text "actual", null: false
    t.text "attempted", null: false
    t.datetime "created_at", null: false
    t.text "expected", null: false
    t.bigint "household_id", null: false
    t.bigint "screenshot_byte_size"
    t.string "screenshot_content_type"
    t.string "screenshot_filename"
    t.string "screenshot_s3_key"
    t.string "status", default: "submitted", null: false
    t.datetime "support_sharing_approved_at"
    t.string "support_sharing_policy_version"
    t.datetime "support_sharing_revoked_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "workflow", null: false
    t.index ["household_id"], name: "index_pilot_feedback_reports_on_household_id"
    t.index ["status", "created_at"], name: "index_pilot_feedback_reports_on_status_and_created_at"
    t.index ["user_id"], name: "index_pilot_feedback_reports_on_user_id"
    t.check_constraint "status::text = ANY (ARRAY['submitted'::character varying, 'reviewed'::character varying, 'resolved'::character varying]::text[])", name: "pilot_feedback_reports_status_valid"
    t.check_constraint "support_sharing_approved_at IS NULL AND support_sharing_policy_version IS NULL OR support_sharing_approved_at IS NOT NULL AND support_sharing_policy_version IS NOT NULL AND support_sharing_policy_version::text = 'technical_support_v1'::text AND (support_sharing_revoked_at IS NULL OR support_sharing_revoked_at >= support_sharing_approved_at)", name: "pilot_feedback_support_sharing_consistent"
    t.check_constraint "workflow::text = ANY (ARRAY['sign_in'::character varying, 'home'::character varying, 'setup'::character varying, 'ask_mia'::character varying, 'voice'::character varying, 'budget'::character varying, 'transaction_review'::character varying, 'receipt_upload'::character varying, 'statement_upload'::character varying, 'document_upload'::character varying, 'private_document'::character varying, 'admin'::character varying, 'other'::character varying]::text[])", name: "pilot_feedback_reports_workflow_valid"
  end

  create_table "plaid_accounts", force: :cascade do |t|
    t.string "account_subtype"
    t.string "account_type", null: false
    t.boolean "active", default: true, null: false
    t.bigint "available_balance_cents"
    t.datetime "created_at", null: false
    t.bigint "current_balance_cents"
    t.integer "financial_generation", default: 0, null: false
    t.string "iso_currency_code"
    t.datetime "last_synced_at"
    t.bigint "limit_balance_cents"
    t.string "mask"
    t.string "name", null: false
    t.string "official_name"
    t.string "persistent_account_id"
    t.string "plaid_account_id", null: false
    t.bigint "plaid_item_id", null: false
    t.datetime "updated_at", null: false
    t.index ["plaid_account_id"], name: "index_plaid_accounts_on_plaid_account_id", unique: true
    t.index ["plaid_item_id"], name: "index_plaid_accounts_on_plaid_item_id"
  end

  create_table "plaid_items", force: :cascade do |t|
    t.text "access_token_ciphertext"
    t.boolean "auto_confirm_trusted_merchants", default: false, null: false
    t.bigint "connected_by_user_id", null: false
    t.datetime "consent_expiration_time"
    t.string "consent_policy_version", null: false
    t.datetime "consented_at", null: false
    t.datetime "created_at", null: false
    t.datetime "disconnected_at"
    t.string "environment", null: false
    t.string "error_code"
    t.string "error_message"
    t.integer "financial_generation", default: 0, null: false
    t.datetime "financial_resumed_at"
    t.bigint "household_id", null: false
    t.string "institution_id"
    t.string "institution_name"
    t.datetime "last_successful_update_at"
    t.datetime "last_synced_at"
    t.string "plaid_item_id", null: false
    t.string "status", default: "active", null: false
    t.text "sync_cursor"
    t.datetime "updated_at", null: false
    t.index ["connected_by_user_id"], name: "index_plaid_items_on_connected_by_user_id"
    t.index ["household_id"], name: "index_plaid_items_on_household_id"
    t.index ["plaid_item_id"], name: "index_plaid_items_on_plaid_item_id", unique: true
    t.check_constraint "environment::text = ANY (ARRAY['sandbox'::character varying, 'production'::character varying]::text[])", name: "plaid_items_environment"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'update_required'::character varying, 'error'::character varying, 'disconnecting'::character varying, 'disconnected'::character varying]::text[])", name: "plaid_items_status"
  end

  create_table "plaid_transactions", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.date "authorized_on"
    t.datetime "created_at", null: false
    t.string "detailed_category"
    t.string "drafted_source_fingerprint"
    t.integer "financial_generation", default: 0, null: false
    t.string "iso_currency_code"
    t.string "merchant_name"
    t.string "name", null: false
    t.date "occurred_on", null: false
    t.string "payment_channel"
    t.boolean "pending", default: false, null: false
    t.string "pending_transaction_id"
    t.bigint "plaid_account_id", null: false
    t.bigint "plaid_item_id", null: false
    t.string "plaid_transaction_id", null: false
    t.string "primary_category"
    t.datetime "removed_at"
    t.string "review_status", default: "unreviewed", null: false
    t.string "source_fingerprint", null: false
    t.bigint "transaction_draft_id"
    t.datetime "updated_at", null: false
    t.index ["plaid_account_id"], name: "index_plaid_transactions_on_plaid_account_id"
    t.index ["plaid_item_id", "occurred_on"], name: "index_plaid_transactions_on_plaid_item_id_and_occurred_on"
    t.index ["plaid_item_id"], name: "index_plaid_transactions_on_plaid_item_id"
    t.index ["plaid_transaction_id"], name: "index_plaid_transactions_on_plaid_transaction_id", unique: true
    t.index ["transaction_draft_id"], name: "index_plaid_transactions_on_transaction_draft_id"
    t.check_constraint "review_status::text = ANY (ARRAY['unreviewed'::character varying, 'drafted'::character varying, 'ignored'::character varying]::text[])", name: "plaid_transactions_review_status"
  end

  create_table "savings_checkpoint_drafts", force: :cascade do |t|
    t.bigint "approved_version_id"
    t.integer "base_head_lock_version", null: false
    t.bigint "base_version_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_checkpoint_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_savings_checkpoint_drafts_on_created_by_user_id"
    t.index ["savings_checkpoint_id"], name: "index_savings_checkpoint_drafts_on_savings_checkpoint_id"
    t.index ["savings_enrollment_id"], name: "index_savings_checkpoint_drafts_on_savings_enrollment_id"
    t.check_constraint "(status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying]::text[])) AND base_head_lock_version >= 0", name: "savings_checkpoint_drafts_state"
    t.check_constraint "jsonb_typeof(snapshot) = 'object'::text", name: "savings_checkpoint_drafts_snapshot"
  end

  create_table "savings_checkpoint_versions", force: :cascade do |t|
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.bigint "previous_version_id"
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_checkpoint_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_checkpoint_versions_on_approved_by_user_id"
    t.index ["id", "savings_checkpoint_id"], name: "savings_checkpoint_versions_scope", unique: true
    t.index ["savings_checkpoint_id", "version_number"], name: "savings_checkpoint_versions_number", unique: true
    t.index ["savings_checkpoint_id"], name: "index_savings_checkpoint_versions_on_savings_checkpoint_id"
    t.index ["savings_enrollment_id"], name: "index_savings_checkpoint_versions_on_savings_enrollment_id"
    t.check_constraint "jsonb_typeof(snapshot) = 'object'::text", name: "savings_checkpoint_versions_snapshot"
    t.check_constraint "version_number > 0", name: "savings_checkpoint_versions_number_valid"
  end

  create_table "savings_checkpoints", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.integer "lock_version", default: 0, null: false
    t.integer "milestone_day", null: false
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["id", "savings_enrollment_id"], name: "savings_checkpoints_scope", unique: true
    t.index ["savings_enrollment_id", "milestone_day"], name: "idx_savings_checkpoint_day", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_checkpoints_on_savings_enrollment_id"
    t.check_constraint "milestone_day = ANY (ARRAY[30, 60, 90])", name: "savings_checkpoint_day_valid"
  end

  create_table "savings_daily_check_in_versions", force: :cascade do |t|
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.integer "daily_sequence", null: false
    t.bigint "previous_version_id"
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_daily_check_in_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.string "spending_state", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_daily_check_in_versions_on_approved_by_user_id"
    t.index ["id", "savings_daily_check_in_id"], name: "savings_daily_check_in_versions_scope", unique: true
    t.index ["savings_daily_check_in_id", "version_number"], name: "savings_daily_check_in_versions_number", unique: true
    t.index ["savings_daily_check_in_id"], name: "idx_on_savings_daily_check_in_id_250be89243"
    t.index ["savings_enrollment_id", "daily_sequence"], name: "savings_daily_check_in_versions_sequence", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_daily_check_in_versions_on_savings_enrollment_id"
    t.check_constraint "daily_sequence > 0", name: "savings_daily_check_in_versions_sequence_valid"
    t.check_constraint "spending_state::text = ANY (ARRAY['spending'::character varying, 'no_spend'::character varying, 'unknown'::character varying]::text[])", name: "savings_daily_check_in_state"
    t.check_constraint "version_number > 0", name: "savings_daily_check_in_versions_number_valid"
  end

  create_table "savings_daily_check_ins", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.date "local_on", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["id", "savings_enrollment_id"], name: "savings_daily_check_ins_scope", unique: true
    t.index ["savings_enrollment_id", "local_on"], name: "idx_daily_check_in_day", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_daily_check_ins_on_savings_enrollment_id"
  end

  create_table "savings_daily_ledgers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "savings_enrollment_id", null: false
    t.integer "sequence", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["savings_enrollment_id"], name: "index_savings_daily_ledgers_on_savings_enrollment_id", unique: true
    t.check_constraint "sequence >= 0", name: "savings_daily_sequence_valid"
  end

  create_table "savings_daily_purchase_drafts", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.bigint "approved_version_id"
    t.integer "base_head_lock_version", null: false
    t.bigint "base_version_id"
    t.string "canonical_digest"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.string "disposition", default: "purchase", null: false
    t.string "link_kind", null: false
    t.bigint "linked_transaction_id"
    t.integer "lock_version", default: 0, null: false
    t.string "merchant", limit: 120, null: false
    t.string "previous_canonical_digest"
    t.date "purchased_on", null: false
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_daily_purchase_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "splits", default: [], null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_savings_daily_purchase_drafts_on_created_by_user_id"
    t.index ["linked_transaction_id"], name: "index_savings_daily_purchase_drafts_on_linked_transaction_id"
    t.index ["savings_daily_purchase_id"], name: "idx_on_savings_daily_purchase_id_3437266630"
    t.index ["savings_enrollment_id"], name: "index_savings_daily_purchase_drafts_on_savings_enrollment_id"
    t.check_constraint "(disposition::text = 'purchase'::text AND amount_cents >= 1 AND amount_cents <= 2147483647 OR disposition::text = 'void'::text AND amount_cents = 0 AND splits = '[]'::jsonb AND link_kind::text = 'manual_new'::text) AND char_length(merchant::text) >= 1 AND char_length(merchant::text) <= 120 AND (link_kind::text = ANY (ARRAY['manual_new'::character varying, 'existing_transaction'::character varying]::text[])) AND jsonb_typeof(splits) = 'array'::text", name: "savings_daily_purchase_drafts_values"
    t.check_constraint "(status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying]::text[])) AND base_head_lock_version >= 0", name: "savings_daily_purchase_drafts_state"
  end

  create_table "savings_daily_purchase_versions", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.integer "daily_sequence", null: false
    t.string "disposition", default: "purchase", null: false
    t.bigint "household_transaction_id", null: false
    t.string "link_kind", null: false
    t.string "merchant", limit: 120, null: false
    t.date "posted_on"
    t.bigint "previous_version_id"
    t.date "purchased_on", null: false
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_daily_purchase_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "splits", default: [], null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_daily_purchase_versions_on_approved_by_user_id"
    t.index ["household_transaction_id"], name: "idx_on_household_transaction_id_33a62012b0"
    t.index ["id", "savings_daily_purchase_id"], name: "savings_daily_purchase_versions_scope", unique: true
    t.index ["savings_daily_purchase_id", "version_number"], name: "savings_daily_purchase_versions_number", unique: true
    t.index ["savings_daily_purchase_id"], name: "idx_on_savings_daily_purchase_id_1ce728900b"
    t.index ["savings_enrollment_id", "daily_sequence"], name: "savings_daily_purchase_versions_sequence", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_daily_purchase_versions_on_savings_enrollment_id"
    t.check_constraint "(disposition::text = 'purchase'::text AND amount_cents >= 1 AND amount_cents <= 2147483647 OR disposition::text = 'void'::text AND amount_cents = 0 AND splits = '[]'::jsonb AND link_kind::text = 'manual_new'::text) AND char_length(merchant::text) >= 1 AND char_length(merchant::text) <= 120 AND (link_kind::text = ANY (ARRAY['manual_new'::character varying, 'existing_transaction'::character varying]::text[])) AND jsonb_typeof(splits) = 'array'::text", name: "savings_daily_purchase_versions_values"
    t.check_constraint "daily_sequence > 0", name: "savings_daily_purchase_versions_sequence_valid"
    t.check_constraint "version_number > 0", name: "savings_daily_purchase_versions_number_valid"
  end

  create_table "savings_daily_purchases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.integer "lock_version", default: 0, null: false
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["id", "savings_enrollment_id"], name: "savings_daily_purchases_scope", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_daily_purchases_on_savings_enrollment_id"
  end

  create_table "savings_daily_reflection_versions", force: :cascade do |t|
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "erased_at"
    t.bigint "erased_by_user_id"
    t.string "feeling_now", limit: 500
    t.string "feeling_then", limit: 500
    t.bigint "previous_version_id"
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_daily_reflection_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_daily_reflection_versions_on_approved_by_user_id"
    t.index ["erased_by_user_id"], name: "index_savings_daily_reflection_versions_on_erased_by_user_id"
    t.index ["id", "savings_daily_reflection_id"], name: "savings_daily_reflection_versions_scope", unique: true
    t.index ["savings_daily_reflection_id", "version_number"], name: "savings_daily_reflection_versions_number", unique: true
    t.index ["savings_daily_reflection_id"], name: "idx_on_savings_daily_reflection_id_299b667705"
    t.index ["savings_enrollment_id"], name: "idx_on_savings_enrollment_id_ae44db91c4"
    t.check_constraint "version_number > 0", name: "savings_daily_reflection_versions_number_valid"
  end

  create_table "savings_daily_reflections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.integer "lock_version", default: 0, null: false
    t.bigint "savings_daily_purchase_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["id", "savings_enrollment_id"], name: "savings_daily_reflections_scope", unique: true
    t.index ["savings_daily_purchase_id"], name: "index_savings_daily_reflections_on_savings_daily_purchase_id", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_daily_reflections_on_savings_enrollment_id"
  end

  create_table "savings_debt_cards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.bigint "household_debt_id"
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "source_tracked_account_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_debt_id"], name: "index_savings_debt_cards_on_household_debt_id"
    t.index ["household_id"], name: "index_savings_debt_cards_on_household_id"
    t.index ["savings_enrollment_id", "household_debt_id"], name: "savings_debt_household_identity_once", unique: true, where: "(household_debt_id IS NOT NULL)"
    t.index ["savings_enrollment_id", "source_tracked_account_id"], name: "savings_debt_canonical_account_once", unique: true, where: "(source_tracked_account_id IS NOT NULL)"
    t.index ["savings_enrollment_id"], name: "index_savings_debt_cards_on_savings_enrollment_id"
    t.index ["source_tracked_account_id"], name: "index_savings_debt_cards_on_source_tracked_account_id"
    t.index ["user_id"], name: "index_savings_debt_cards_on_user_id"
  end

  create_table "savings_debt_drafts", force: :cascade do |t|
    t.bigint "approved_version_id"
    t.integer "base_head_lock_version", null: false
    t.bigint "base_version_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.string "household_debt_fingerprint"
    t.bigint "household_debt_id"
    t.jsonb "household_debt_snapshot", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.text "reason", default: "", null: false
    t.bigint "savings_debt_card_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "source_account_identity_version_id"
    t.string "source_fingerprint"
    t.bigint "source_revision_approval_id"
    t.jsonb "source_snapshot", default: {}, null: false
    t.bigint "source_tracked_account_id"
    t.string "status", default: "pending", null: false
    t.jsonb "terms", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_savings_debt_drafts_on_created_by_user_id"
    t.index ["household_debt_id"], name: "index_savings_debt_drafts_on_household_debt_id"
    t.index ["savings_debt_card_id"], name: "index_savings_debt_drafts_on_savings_debt_card_id"
    t.index ["savings_enrollment_id"], name: "index_savings_debt_drafts_on_savings_enrollment_id"
    t.index ["source_account_identity_version_id"], name: "idx_on_source_account_identity_version_id_d819faade4"
    t.index ["source_revision_approval_id"], name: "index_savings_debt_drafts_on_source_revision_approval_id"
    t.index ["source_tracked_account_id"], name: "index_savings_debt_drafts_on_source_tracked_account_id"
    t.check_constraint "base_head_lock_version >= 0 AND (status::text = 'pending'::text AND approved_version_id IS NULL OR status::text = 'approved'::text AND approved_version_id IS NOT NULL)", name: "savings_debt_draft_state"
    t.check_constraint "household_debt_id IS NULL AND household_debt_fingerprint IS NULL AND household_debt_snapshot = '{}'::jsonb OR household_debt_id IS NOT NULL AND household_debt_fingerprint IS NOT NULL AND household_debt_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(household_debt_snapshot) = 'object'::text AND household_debt_snapshot ? 'id'::text AND (household_debt_snapshot -> 'id'::text) = to_jsonb(household_debt_id)", name: "savings_debt_drafts_household_link_complete"
    t.check_constraint "length(reason) <= 500", name: "savings_debt_drafts_reason_length"
    t.check_constraint "savings_debt_terms_valid(terms)", name: "savings_debt_drafts_terms_valid"
    t.check_constraint "source_tracked_account_id IS NULL AND source_account_identity_version_id IS NULL AND source_revision_approval_id IS NULL AND source_fingerprint IS NULL AND source_snapshot = '{}'::jsonb OR source_tracked_account_id IS NOT NULL AND source_account_identity_version_id IS NOT NULL AND source_revision_approval_id IS NOT NULL AND source_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(source_snapshot) = 'object'::text", name: "savings_debt_drafts_mapping_complete"
  end

  create_table "savings_debt_versions", force: :cascade do |t|
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.string "household_debt_fingerprint"
    t.bigint "household_debt_id"
    t.jsonb "household_debt_snapshot", default: {}, null: false
    t.bigint "previous_version_id"
    t.text "reason", default: "", null: false
    t.bigint "savings_debt_card_id", null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "source_account_identity_version_id"
    t.string "source_fingerprint"
    t.bigint "source_revision_approval_id"
    t.jsonb "source_snapshot", default: {}, null: false
    t.bigint "source_tracked_account_id"
    t.jsonb "terms", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_debt_versions_on_approved_by_user_id"
    t.index ["household_debt_id"], name: "index_savings_debt_versions_on_household_debt_id"
    t.index ["id", "savings_debt_card_id"], name: "savings_debt_version_head_identity", unique: true
    t.index ["savings_debt_card_id", "version_number"], name: "savings_debt_version_sequence", unique: true
    t.index ["savings_debt_card_id"], name: "index_savings_debt_versions_on_savings_debt_card_id"
    t.index ["savings_enrollment_id"], name: "index_savings_debt_versions_on_savings_enrollment_id"
    t.index ["source_account_identity_version_id"], name: "idx_on_source_account_identity_version_id_2f27e4803d"
    t.index ["source_revision_approval_id"], name: "index_savings_debt_versions_on_source_revision_approval_id"
    t.index ["source_tracked_account_id"], name: "index_savings_debt_versions_on_source_tracked_account_id"
    t.check_constraint "household_debt_id IS NULL AND household_debt_fingerprint IS NULL AND household_debt_snapshot = '{}'::jsonb OR household_debt_id IS NOT NULL AND household_debt_fingerprint IS NOT NULL AND household_debt_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(household_debt_snapshot) = 'object'::text AND household_debt_snapshot ? 'id'::text AND (household_debt_snapshot -> 'id'::text) = to_jsonb(household_debt_id)", name: "savings_debt_versions_household_link_complete"
    t.check_constraint "length(reason) <= 500", name: "savings_debt_versions_reason_length"
    t.check_constraint "savings_debt_terms_valid(terms)", name: "savings_debt_versions_terms_valid"
    t.check_constraint "source_tracked_account_id IS NULL AND source_account_identity_version_id IS NULL AND source_revision_approval_id IS NULL AND source_fingerprint IS NULL AND source_snapshot = '{}'::jsonb OR source_tracked_account_id IS NOT NULL AND source_account_identity_version_id IS NOT NULL AND source_revision_approval_id IS NOT NULL AND source_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(source_snapshot) = 'object'::text", name: "savings_debt_versions_mapping_complete"
    t.check_constraint "version_number > 0 AND digest::text ~ '^[0-9a-f]{64}$'::text", name: "savings_debt_approved_digest"
  end

  create_table "savings_enrollments", force: :cascade do |t|
    t.datetime "accepted_at", null: false
    t.bigint "accepted_cohort_membership_id", null: false
    t.bigint "accepted_cohort_release_id"
    t.date "accepted_local_on", null: false
    t.integer "approval_sequence", default: 0, null: false
    t.bigint "cohort_id", null: false
    t.datetime "created_at", null: false
    t.bigint "current_accepted_plan_version_id"
    t.date "ends_on", null: false
    t.bigint "household_id", null: false
    t.boolean "late_start_accepted", default: false, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "membership_started_at", null: false
    t.string "policy_version", null: false
    t.date "starts_on", null: false
    t.string "status", default: "active", null: false
    t.string "time_zone", default: "Pacific/Guam", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["accepted_cohort_release_id"], name: "index_savings_enrollments_on_accepted_cohort_release_id"
    t.index ["cohort_id", "user_id"], name: "index_savings_enrollments_on_cohort_id_and_user_id", unique: true
    t.index ["cohort_id"], name: "index_savings_enrollments_on_cohort_id"
    t.index ["household_id"], name: "index_savings_enrollments_on_household_id"
    t.index ["user_id"], name: "index_savings_enrollments_on_user_id"
    t.check_constraint "(status::text = ANY (ARRAY['active'::character varying, 'withdrawn'::character varying, 'completed'::character varying]::text[])) AND approval_sequence >= 0", name: "savings_enrollment_state_valid"
    t.check_constraint "ends_on = (starts_on + 89) AND time_zone::text = 'Pacific/Guam'::text AND starts_on >= accepted_local_on", name: "savings_enrollment_calendar_valid"
  end

  create_table "savings_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_approved_version_id"
    t.integer "lock_version", default: 0, null: false
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["id", "savings_enrollment_id"], name: "idx_savings_entry_scope", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_entries_on_savings_enrollment_id"
  end

  create_table "savings_entry_drafts", force: :cascade do |t|
    t.bigint "approved_version_id"
    t.integer "base_entry_lock_version", null: false
    t.bigint "base_version_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.date "effective_on", null: false
    t.string "funding_source", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_entry_id", null: false
    t.bigint "signed_cents", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_savings_entry_drafts_on_created_by_user_id"
    t.index ["savings_entry_id"], name: "index_savings_entry_drafts_on_savings_entry_id"
    t.check_constraint "(status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying]::text[])) AND base_entry_lock_version >= 0", name: "savings_entry_draft_state_valid"
  end

  create_table "savings_entry_versions", force: :cascade do |t|
    t.integer "approval_sequence", null: false
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.date "effective_on", null: false
    t.bigint "evidence_supported_cents", default: 0, null: false
    t.string "funding_source", null: false
    t.bigint "previous_version_id"
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "savings_entry_id", null: false
    t.bigint "signed_cents", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_entry_versions_on_approved_by_user_id"
    t.index ["id", "savings_entry_id"], name: "idx_savings_version_scope", unique: true
    t.index ["savings_enrollment_id", "approval_sequence"], name: "idx_savings_entry_approval_sequence", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_entry_versions_on_savings_enrollment_id"
    t.index ["savings_entry_id", "version_number"], name: "idx_savings_entry_version_number", unique: true
    t.index ["savings_entry_id"], name: "index_savings_entry_versions_on_savings_entry_id"
    t.check_constraint "currency::text = 'USD'::text AND evidence_supported_cents = 0 AND version_number > 0 AND approval_sequence > 0 AND (funding_source::text = 'withdrawal'::text AND signed_cents <= 0 OR (funding_source::text = ANY (ARRAY['earned_income'::character varying, 'gift'::character varying, 'bonus'::character varying, 'new_money_reserved'::character varying, 'preexisting'::character varying, 'borrowed'::character varying, 'cash_advance'::character varying, 'existing_internal_money'::character varying]::text[])) AND signed_cents >= 0)", name: "savings_entry_version_values_valid"
  end

  create_table "savings_evidence_allocations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "savings_entry_version_id", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_savings_evidence_allocations_on_household_id"
    t.index ["savings_enrollment_id"], name: "index_savings_evidence_allocations_on_savings_enrollment_id"
    t.index ["savings_entry_version_id"], name: "index_savings_evidence_allocations_on_savings_entry_version_id", unique: true
  end

  create_table "savings_evidence_capacities", force: :cascade do |t|
    t.bigint "capacity_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "financial_source_event_id", null: false
    t.bigint "reserved_cents", null: false
    t.bigint "savings_evidence_version_id", null: false
    t.bigint "source_review_version_id", null: false
    t.datetime "updated_at", null: false
    t.index ["financial_source_event_id"], name: "index_savings_evidence_capacities_on_financial_source_event_id"
    t.index ["savings_evidence_version_id", "financial_source_event_id"], name: "savings_evidence_event_once", unique: true
    t.index ["savings_evidence_version_id"], name: "idx_on_savings_evidence_version_id_cd330512e5"
    t.index ["source_review_version_id"], name: "index_savings_evidence_capacities_on_source_review_version_id"
    t.check_constraint "reserved_cents > 0 AND capacity_cents >= reserved_cents", name: "savings_evidence_capacity_values"
  end

  create_table "savings_evidence_versions", force: :cascade do |t|
    t.integer "approval_sequence", null: false
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.boolean "new_money_reservation_accepted", null: false
    t.boolean "participant_ownership_accepted", null: false
    t.bigint "previous_version_id"
    t.jsonb "proof_snapshot", default: [], null: false
    t.string "reason", limit: 500, null: false
    t.bigint "savings_enrollment_id", null: false
    t.bigint "savings_evidence_allocation_id", null: false
    t.string "state", null: false
    t.bigint "supported_cents", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_evidence_versions_on_approved_by_user_id"
    t.index ["id", "savings_evidence_allocation_id"], name: "savings_evidence_version_scope", unique: true
    t.index ["savings_enrollment_id", "approval_sequence"], name: "savings_evidence_sequence", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_evidence_versions_on_savings_enrollment_id"
    t.index ["savings_evidence_allocation_id", "version_number"], name: "savings_evidence_version_number", unique: true
    t.index ["savings_evidence_allocation_id"], name: "idx_on_savings_evidence_allocation_id_e637836c7f"
    t.check_constraint "version_number > 0 AND approval_sequence > 0 AND char_length(reason::text) >= 1 AND char_length(reason::text) <= 500 AND digest::text ~ '^[0-9a-f]{64}$'::text AND jsonb_typeof(proof_snapshot) = 'array'::text AND (state::text = 'attached'::text AND supported_cents > 0 AND participant_ownership_accepted AND new_money_reservation_accepted AND jsonb_array_length(proof_snapshot) >= 1 AND jsonb_array_length(proof_snapshot) <= 20 OR state::text = 'revoked'::text AND supported_cents = 0 AND NOT participant_ownership_accepted AND NOT new_money_reservation_accepted AND proof_snapshot = '[]'::jsonb)", name: "savings_evidence_values"
  end

  create_table "savings_plan_drafts", force: :cascade do |t|
    t.bigint "approved_plan_version_id"
    t.bigint "base_plan_version_id"
    t.string "baseline_digest"
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "financial_baseline_version_id"
    t.integer "lock_version", default: 0, null: false
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "spending_changes", default: [], null: false
    t.string "status", default: "pending", null: false
    t.bigint "target_cents"
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_savings_plan_drafts_on_created_by_user_id"
    t.index ["financial_baseline_version_id"], name: "index_savings_plan_drafts_on_financial_baseline_version_id"
    t.index ["savings_enrollment_id"], name: "index_savings_plan_drafts_on_savings_enrollment_id"
    t.check_constraint "(target_cents IS NULL OR target_cents > 0) AND (status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying]::text[]))", name: "savings_plan_draft_values_valid"
    t.check_constraint "jsonb_typeof(spending_changes) = 'array'::text AND jsonb_array_length(spending_changes) <= 5 AND (financial_baseline_version_id IS NULL AND baseline_digest IS NULL OR financial_baseline_version_id IS NOT NULL AND baseline_digest::text ~ '^[0-9a-f]{64}$'::text)", name: "savings_plan_drafts_context_valid"
  end

  create_table "savings_plan_versions", force: :cascade do |t|
    t.integer "approval_sequence", null: false
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.string "baseline_digest"
    t.datetime "created_at", null: false
    t.bigint "financial_baseline_version_id"
    t.bigint "previous_version_id"
    t.string "reason", limit: 500, default: "", null: false
    t.bigint "savings_enrollment_id", null: false
    t.jsonb "spending_changes", default: [], null: false
    t.bigint "target_cents"
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_savings_plan_versions_on_approved_by_user_id"
    t.index ["financial_baseline_version_id"], name: "index_savings_plan_versions_on_financial_baseline_version_id"
    t.index ["id", "savings_enrollment_id"], name: "idx_savings_plan_scope", unique: true
    t.index ["savings_enrollment_id", "version_number"], name: "idx_savings_plan_number", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_plan_versions_on_savings_enrollment_id"
    t.check_constraint "(target_cents IS NULL OR target_cents > 0) AND version_number > 0 AND approval_sequence > 0", name: "savings_plan_values_valid"
    t.check_constraint "jsonb_typeof(spending_changes) = 'array'::text AND jsonb_array_length(spending_changes) <= 5 AND (financial_baseline_version_id IS NULL AND baseline_digest IS NULL OR financial_baseline_version_id IS NOT NULL AND baseline_digest::text ~ '^[0-9a-f]{64}$'::text)", name: "savings_plan_versions_context_valid"
  end

  create_table "savings_zero_attestations", force: :cascade do |t|
    t.integer "approval_sequence", null: false
    t.datetime "approved_at", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.date "cutoff_on", null: false
    t.bigint "previous_attestation_id"
    t.bigint "savings_enrollment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_user_id"], name: "index_savings_zero_attestations_on_approved_by_user_id"
    t.index ["savings_enrollment_id", "approval_sequence"], name: "idx_savings_zero_approval_sequence", unique: true
    t.index ["savings_enrollment_id"], name: "index_savings_zero_attestations_on_savings_enrollment_id"
  end

  create_table "setup_help_request_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "idempotency_key", limit: 200, null: false
    t.string "request_fingerprint", null: false
    t.bigint "setup_support_request_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_id", "user_id", "idempotency_key"], name: "setup_help_request_identity", unique: true
    t.index ["household_id"], name: "index_setup_help_request_keys_on_household_id"
    t.index ["setup_support_request_id"], name: "index_setup_help_request_keys_on_setup_support_request_id"
    t.index ["user_id"], name: "index_setup_help_request_keys_on_user_id"
  end

  create_table "setup_support_requests", force: :cascade do |t|
    t.bigint "cohort_id"
    t.datetime "created_at", null: false
    t.bigint "financial_restart_review_id"
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "participant_membership_id"
    t.datetime "participant_membership_started_at"
    t.bigint "prepared_by_user_id"
    t.string "reason", null: false
    t.bigint "requested_by_user_id", null: false
    t.string "status", default: "requested", null: false
    t.datetime "updated_at", null: false
    t.index ["cohort_id"], name: "index_setup_support_requests_on_cohort_id"
    t.index ["financial_restart_review_id"], name: "index_setup_support_requests_on_financial_restart_review_id"
    t.index ["household_id", "requested_by_user_id", "cohort_id"], name: "setup_support_active_program", unique: true, where: "((cohort_id IS NOT NULL) AND ((status)::text = ANY (ARRAY[('requested'::character varying)::text, ('in_review'::character varying)::text, ('ready'::character varying)::text])))"
    t.index ["household_id", "requested_by_user_id"], name: "setup_support_active_personal", unique: true, where: "((cohort_id IS NULL) AND ((status)::text = ANY (ARRAY[('requested'::character varying)::text, ('in_review'::character varying)::text, ('ready'::character varying)::text])))"
    t.index ["household_id"], name: "index_setup_support_requests_on_household_id"
    t.index ["prepared_by_user_id"], name: "index_setup_support_requests_on_prepared_by_user_id"
    t.index ["requested_by_user_id"], name: "index_setup_support_requests_on_requested_by_user_id"
    t.check_constraint "cohort_id IS NULL AND participant_membership_id IS NULL AND participant_membership_started_at IS NULL OR cohort_id IS NOT NULL AND participant_membership_id IS NOT NULL AND participant_membership_started_at IS NOT NULL", name: "setup_support_program_identity"
    t.check_constraint "reason::text = ANY (ARRAY['practice_numbers'::character varying, 'wrong_setup'::character varying, 'upload_problem'::character varying, 'other'::character varying]::text[])", name: "setup_support_reason"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying, 'in_review'::character varying, 'ready'::character varying, 'applied'::character varying, 'canceled'::character varying, 'declined'::character varying]::text[])", name: "setup_support_status"
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

  create_table "source_account_identity_versions", force: :cascade do |t|
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.bigint "household_id", null: false
    t.text "reason", null: false
    t.bigint "source_account_review_head_id", null: false
    t.bigint "source_tracked_account_id", null: false
    t.jsonb "statement_facts", default: {}, null: false
    t.bigint "supersedes_id"
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_source_account_identity_versions_on_approved_by_user_id"
    t.index ["household_id"], name: "index_source_account_identity_versions_on_household_id"
    t.index ["id", "household_id"], name: "source_account_identity_versions_household_identity", unique: true
    t.index ["id", "source_account_review_head_id", "household_id"], name: "source_account_identity_versions_head_identity", unique: true
    t.index ["source_account_review_head_id", "version_number"], name: "source_account_identity_versions_sequence", unique: true
    t.index ["source_account_review_head_id"], name: "idx_on_source_account_review_head_id_e2c9b31699"
    t.index ["source_tracked_account_id"], name: "idx_on_source_tracked_account_id_819c892e5d"
  end

  create_table "source_account_review_heads", force: :cascade do |t|
    t.bigint "approved_version_id"
    t.datetime "created_at", null: false
    t.bigint "financial_source_account_id", null: false
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["financial_source_account_id"], name: "idx_on_financial_source_account_id_2d4c199d7c", unique: true
    t.index ["household_id"], name: "index_source_account_review_heads_on_household_id"
    t.index ["id", "household_id"], name: "source_account_review_heads_household_identity", unique: true
  end

  create_table "source_economic_group_versions", force: :cascade do |t|
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.bigint "household_id", null: false
    t.string "kind", null: false
    t.text "reason", null: false
    t.bigint "source_economic_group_id", null: false
    t.bigint "supersedes_id"
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_source_economic_group_versions_on_approved_by_user_id"
    t.index ["household_id"], name: "index_source_economic_group_versions_on_household_id"
    t.index ["id", "household_id"], name: "source_economic_group_versions_household_identity", unique: true
    t.index ["id", "source_economic_group_id", "household_id"], name: "source_economic_group_versions_head_identity", unique: true
    t.index ["source_economic_group_id", "version_number"], name: "source_economic_group_versions_sequence", unique: true
    t.index ["source_economic_group_id"], name: "idx_on_source_economic_group_id_d237f224b8"
    t.check_constraint "kind::text = ANY (ARRAY['transfer'::character varying, 'purchase_funding'::character varying, 'refund'::character varying]::text[])", name: "source_economic_kind"
  end

  create_table "source_economic_groups", force: :cascade do |t|
    t.bigint "approved_version_id"
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_source_economic_groups_on_household_id"
    t.index ["id", "household_id"], name: "source_economic_groups_household_identity", unique: true
  end

  create_table "source_economic_memberships", force: :cascade do |t|
    t.bigint "allocation_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "role", null: false
    t.bigint "source_economic_group_version_id", null: false
    t.bigint "source_review_version_id", null: false
    t.index ["household_id"], name: "index_source_economic_memberships_on_household_id"
    t.index ["id", "household_id"], name: "source_economic_memberships_household_identity", unique: true
    t.index ["source_economic_group_version_id", "source_review_version_id", "role"], name: "source_economic_members_unique", unique: true
    t.index ["source_economic_group_version_id"], name: "idx_on_source_economic_group_version_id_9d85718370"
    t.index ["source_review_version_id"], name: "index_source_economic_memberships_on_source_review_version_id"
    t.check_constraint "allocation_cents > 0", name: "source_economic_allocation"
  end

  create_table "source_projection_revisions", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.bigint "household_id", null: false
    t.string "previous_snapshot_digest"
    t.bigint "previous_transaction_id"
    t.text "reason", null: false
    t.bigint "replacement_transaction_id"
    t.bigint "source_review_version_id", null: false
    t.index ["approved_by_user_id"], name: "index_source_projection_revisions_on_approved_by_user_id"
    t.index ["household_id"], name: "index_source_projection_revisions_on_household_id"
    t.index ["id", "household_id"], name: "source_projection_revisions_household_identity", unique: true
    t.index ["previous_transaction_id"], name: "index_source_projection_revisions_on_previous_transaction_id"
    t.index ["replacement_transaction_id"], name: "idx_on_replacement_transaction_id_b16ab0c6b9"
    t.index ["source_review_version_id"], name: "index_source_projection_revisions_on_source_review_version_id", unique: true
    t.check_constraint "action::text = ANY (ARRAY['create'::character varying, 'replace'::character varying, 'void'::character varying]::text[])", name: "source_projection_action"
  end

  create_table "source_review_drafts", force: :cascade do |t|
    t.integer "base_head_lock_version", null: false
    t.bigint "base_version_id"
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.jsonb "facts", null: false
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.jsonb "projection", default: {}, null: false
    t.text "reason", null: false
    t.bigint "source_review_head_id", null: false
    t.bigint "staged_by_user_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_source_review_drafts_on_household_id"
    t.index ["id", "household_id"], name: "source_review_drafts_household_identity", unique: true
    t.index ["source_review_head_id"], name: "index_source_review_drafts_on_source_review_head_id"
    t.index ["source_review_head_id"], name: "source_one_pending_draft", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["staged_by_user_id"], name: "index_source_review_drafts_on_staged_by_user_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying, 'cancelled'::character varying]::text[])", name: "source_review_draft_status"
  end

  create_table "source_review_heads", force: :cascade do |t|
    t.bigint "approved_version_id"
    t.datetime "created_at", null: false
    t.bigint "financial_source_event_id", null: false
    t.bigint "household_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["financial_source_event_id"], name: "index_source_review_heads_on_financial_source_event_id", unique: true
    t.index ["household_id"], name: "index_source_review_heads_on_household_id"
    t.index ["id", "household_id"], name: "source_review_heads_household_identity", unique: true
  end

  create_table "source_review_versions", force: :cascade do |t|
    t.bigint "approved_by_user_id", null: false
    t.date "authorized_on"
    t.bigint "budget_category_id"
    t.jsonb "category_snapshot", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.string "disposition", null: false
    t.string "event_type", null: false
    t.string "external_reference"
    t.bigint "household_id", null: false
    t.bigint "matched_version_id"
    t.string "merchant"
    t.string "overlap_disposition", null: false
    t.date "posted_on"
    t.jsonb "projection", default: {}, null: false
    t.bigint "purchase_amount_cents"
    t.text "reason", null: false
    t.bigint "signed_amount_cents"
    t.bigint "source_account_identity_version_id", null: false
    t.string "source_artifact_digest"
    t.bigint "source_review_head_id", null: false
    t.bigint "supersedes_id"
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_source_review_versions_on_approved_by_user_id"
    t.index ["budget_category_id"], name: "index_source_review_versions_on_budget_category_id"
    t.index ["household_id"], name: "index_source_review_versions_on_household_id"
    t.index ["id", "household_id"], name: "source_review_versions_household_identity", unique: true
    t.index ["id", "source_review_head_id", "household_id"], name: "source_review_versions_head_identity", unique: true
    t.index ["source_account_identity_version_id"], name: "idx_on_source_account_identity_version_id_48cebccb51"
    t.index ["source_review_head_id", "version_number"], name: "source_review_versions_sequence", unique: true
    t.index ["source_review_head_id"], name: "index_source_review_versions_on_source_review_head_id"
    t.check_constraint "(disposition::text <> ALL (ARRAY['include'::character varying, 'match'::character varying]::text[])) OR signed_amount_cents IS NOT NULL AND signed_amount_cents <> 0 AND posted_on IS NOT NULL AND event_type::text <> 'unknown'::text", name: "source_review_posted_facts"
    t.check_constraint "disposition::text = ANY (ARRAY['include'::character varying, 'match'::character varying, 'exclude'::character varying, 'informational'::character varying]::text[])", name: "source_review_disposition"
    t.check_constraint "event_type::text = ANY (ARRAY['purchase'::character varying, 'fee'::character varying, 'refund'::character varying, 'income'::character varying, 'transfer'::character varying, 'debt_payment'::character varying, 'cash_withdrawal'::character varying, 'interest'::character varying, 'adjustment'::character varying, 'unknown'::character varying]::text[])", name: "source_review_event_type"
  end

  create_table "source_revision_approvals", force: :cascade do |t|
    t.jsonb "account_version_ids", default: [], null: false
    t.bigint "approved_by_user_id", null: false
    t.jsonb "coverage_attestation", null: false
    t.string "coverage_status", null: false
    t.datetime "created_at", null: false
    t.jsonb "deficiencies", default: [], null: false
    t.jsonb "dependencies", default: {}, null: false
    t.string "digest", null: false
    t.bigint "financial_extraction_revision_id", null: false
    t.bigint "household_id", null: false
    t.text "reason", null: false
    t.jsonb "source_version_ids", default: [], null: false
    t.bigint "supersedes_id"
    t.integer "version_number", null: false
    t.index ["approved_by_user_id"], name: "index_source_revision_approvals_on_approved_by_user_id"
    t.index ["financial_extraction_revision_id", "version_number"], name: "source_revision_approval_sequence", unique: true
    t.index ["financial_extraction_revision_id"], name: "idx_on_financial_extraction_revision_id_131641a13b"
    t.index ["household_id"], name: "index_source_revision_approvals_on_household_id"
    t.index ["id", "household_id"], name: "source_revision_approvals_household_identity", unique: true
    t.check_constraint "coverage_status::text = ANY (ARRAY['complete'::character varying, 'qualified'::character varying]::text[])", name: "source_revision_coverage"
  end

  create_table "source_tracked_accounts", force: :cascade do |t|
    t.string "account_basis", null: false
    t.bigint "account_id"
    t.bigint "approved_by_user_id", null: false
    t.datetime "created_at", null: false
    t.integer "financial_generation", default: 0, null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.index ["account_id"], name: "index_source_tracked_accounts_on_account_id"
    t.index ["approved_by_user_id"], name: "index_source_tracked_accounts_on_approved_by_user_id"
    t.index ["household_id"], name: "index_source_tracked_accounts_on_household_id"
    t.index ["id", "household_id"], name: "source_tracked_accounts_household_identity", unique: true
    t.check_constraint "account_basis::text = ANY (ARRAY['asset'::character varying, 'liability'::character varying]::text[])", name: "source_tracked_basis"
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
    t.integer "financial_generation", default: 0, null: false
    t.bigint "financial_source_event_id"
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
    t.index ["financial_source_event_id"], name: "index_transaction_drafts_on_financial_source_event_id"
    t.index ["household_id", "status", "created_at"], name: "idx_on_household_id_status_created_at_cf0ad72279"
    t.index ["household_id"], name: "index_transaction_drafts_on_household_id"
    t.index ["matched_transaction_id"], name: "index_transaction_drafts_on_matched_transaction_id"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_chat'::character varying, 'manual_ui'::character varying, 'receipt'::character varying, 'screenshot'::character varying, 'statement'::character varying, 'import'::character varying, 'plaid'::character varying]::text[])", name: "transaction_drafts_source_type_valid"
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

  create_table "workos_browser_login_attempts", force: :cascade do |t|
    t.boolean "popup", default: false, null: false
    t.string "browser_digest", null: false
    t.string "client_id", null: false
    t.datetime "created_at", null: false
    t.text "encrypted_verifier", null: false
    t.datetime "expires_at", null: false
    t.string "frontend_origin", null: false
    t.string "return_to", null: false
    t.string "state_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_workos_browser_login_attempts_on_expires_at"
    t.index ["state_digest"], name: "index_workos_browser_login_attempts_on_state_digest", unique: true
  end

  create_table "workos_email_delivery_limits", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "delivery_count", default: 0, null: false
    t.string "identity_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "window_started_at", null: false
    t.index ["identity_digest"], name: "index_workos_email_delivery_limits_on_identity_digest", unique: true
    t.index ["updated_at"], name: "index_workos_email_delivery_limits_on_updated_at"
  end

  create_table "workos_email_challenges", force: :cascade do |t|
    t.string "browser_digest", null: false
    t.string "challenge_digest", null: false
    t.string "client_id", null: false
    t.datetime "created_at", null: false
    t.text "encrypted_context", null: false
    t.datetime "expires_at", null: false
    t.string "frontend_origin", null: false
    t.datetime "resend_at", null: false
    t.datetime "updated_at", null: false
    t.integer "verification_attempts", default: 0, null: false
    t.index ["challenge_digest"], name: "index_workos_email_challenges_on_challenge_digest", unique: true
    t.index ["expires_at"], name: "index_workos_email_challenges_on_expires_at"
  end

  create_table "workos_browser_sessions", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "cookie_digest", null: false
    t.datetime "created_at", null: false
    t.text "encrypted_credentials", null: false
    t.datetime "expires_at", null: false
    t.string "frontend_origin", null: false
    t.string "provider_session_id", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.index ["cookie_digest"], name: "index_workos_browser_sessions_on_cookie_digest", unique: true
    t.index ["expires_at"], name: "index_workos_browser_sessions_on_expires_at"
  end

  create_table "workspace_brand_configurations", force: :cascade do |t|
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "current_published_version_id"
    t.jsonb "draft_config", default: {}, null: false
    t.integer "draft_revision", default: 1, null: false
    t.bigint "last_edited_by_user_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "preview_digest"
    t.datetime "previewed_at"
    t.integer "previewed_draft_revision"
    t.datetime "updated_at", null: false
    t.index ["coach_workspace_id"], name: "index_workspace_brand_configurations_on_coach_workspace_id", unique: true
    t.index ["current_published_version_id"], name: "idx_on_current_published_version_id_6bd2a0be79"
    t.index ["id", "coach_workspace_id"], name: "idx_workspace_brand_configs_id_workspace", unique: true
    t.index ["last_edited_by_user_id"], name: "index_workspace_brand_configurations_on_last_edited_by_user_id"
    t.check_constraint "draft_revision > 0", name: "workspace_brand_configurations_positive_revision"
    t.check_constraint "jsonb_typeof(draft_config) = 'object'::text", name: "workspace_brand_configurations_draft_object"
    t.check_constraint "octet_length(draft_config::text) <= 16384", name: "workspace_brand_configurations_draft_bytes"
    t.check_constraint "preview_digest IS NULL AND previewed_draft_revision IS NULL AND previewed_at IS NULL OR preview_digest IS NOT NULL AND previewed_draft_revision IS NOT NULL AND previewed_at IS NOT NULL", name: "workspace_brand_configurations_preview_complete"
    t.check_constraint "preview_digest IS NULL OR preview_digest::text ~ '^[0-9a-f]{64}$'::text", name: "workspace_brand_configurations_preview_digest"
  end

  create_table "workspace_brand_publication_events", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "idempotency_key", null: false
    t.string "request_fingerprint", null: false
    t.bigint "source_version_id"
    t.datetime "updated_at", null: false
    t.bigint "workspace_brand_configuration_id", null: false
    t.bigint "workspace_brand_version_id", null: false
    t.index ["actor_user_id"], name: "index_workspace_brand_publication_events_on_actor_user_id"
    t.index ["source_version_id"], name: "index_workspace_brand_publication_events_on_source_version_id"
    t.index ["workspace_brand_configuration_id", "idempotency_key"], name: "idx_workspace_brand_events_idempotency", unique: true
    t.index ["workspace_brand_configuration_id"], name: "idx_workspace_brand_events_configuration"
    t.index ["workspace_brand_version_id"], name: "idx_workspace_brand_events_version"
    t.check_constraint "char_length(idempotency_key::text) >= 1 AND char_length(idempotency_key::text) <= 255", name: "workspace_brand_publication_events_idempotency_length"
    t.check_constraint "event_type::text = ANY (ARRAY['publish'::character varying, 'rollback'::character varying]::text[])", name: "workspace_brand_publication_events_type"
    t.check_constraint "request_fingerprint::text ~ '^[0-9a-f]{64}$'::text", name: "workspace_brand_publication_events_request_fingerprint"
  end

  create_table "workspace_brand_versions", force: :cascade do |t|
    t.bigint "coach_workspace_id", null: false
    t.jsonb "config", null: false
    t.string "config_digest", null: false
    t.datetime "created_at", null: false
    t.bigint "published_by_user_id", null: false
    t.bigint "source_version_id"
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.bigint "workspace_brand_configuration_id", null: false
    t.index ["id", "coach_workspace_id"], name: "idx_workspace_brand_versions_id_workspace", unique: true
    t.index ["id", "workspace_brand_configuration_id"], name: "idx_workspace_brand_versions_id_config", unique: true
    t.index ["published_by_user_id"], name: "index_workspace_brand_versions_on_published_by_user_id"
    t.index ["source_version_id"], name: "index_workspace_brand_versions_on_source_version_id"
    t.index ["workspace_brand_configuration_id", "version_number"], name: "idx_workspace_brand_versions_config_number", unique: true
    t.check_constraint "config_digest::text ~ '^[0-9a-f]{64}$'::text", name: "workspace_brand_versions_digest"
    t.check_constraint "jsonb_typeof(config) = 'object'::text", name: "workspace_brand_versions_config_object"
    t.check_constraint "octet_length(config::text) <= 16384", name: "workspace_brand_versions_config_bytes"
    t.check_constraint "version_number > 0", name: "workspace_brand_versions_positive_number"
  end

  add_foreign_key "accounts", "households"
  add_foreign_key "accounts", "plaid_accounts", on_delete: :nullify
  add_foreign_key "authentication_identities", "users"
  add_foreign_key "budget_allocations", "budget_categories"
  add_foreign_key "budget_allocations", "budget_periods"
  add_foreign_key "budget_categories", "households"
  add_foreign_key "budget_periods", "budget_years"
  add_foreign_key "budget_years", "households"
  add_foreign_key "challenge_privacy_events", "households"
  add_foreign_key "challenge_privacy_events", "savings_enrollments"
  add_foreign_key "challenge_privacy_events", "users", column: "actor_user_id"
  add_foreign_key "challenge_privacy_events", "users", column: "participant_user_id"
  add_foreign_key "challenge_privacy_grants", "households"
  add_foreign_key "challenge_privacy_grants", "savings_enrollments"
  add_foreign_key "challenge_privacy_grants", "users", column: "participant_user_id"
  add_foreign_key "challenge_privacy_grants", "users", column: "recipient_user_id"
  add_foreign_key "challenge_privacy_reads", "households"
  add_foreign_key "challenge_privacy_reads", "savings_enrollments"
  add_foreign_key "challenge_privacy_reads", "users", column: "actor_user_id"
  add_foreign_key "challenge_privacy_reads", "users", column: "participant_user_id"
  add_foreign_key "challenge_reminder_events", "households"
  add_foreign_key "challenge_reminder_events", "savings_enrollments"
  add_foreign_key "challenge_reminder_events", "users", column: "actor_user_id"
  add_foreign_key "challenge_reminder_events", "users", column: "participant_user_id"
  add_foreign_key "challenge_reminder_preferences", "households"
  add_foreign_key "challenge_reminder_preferences", "savings_enrollments"
  add_foreign_key "challenge_reminder_preferences", "users", column: "participant_user_id"
  add_foreign_key "challenge_reminders", "challenge_reminder_preferences"
  add_foreign_key "challenge_reminders", "households"
  add_foreign_key "challenge_reminders", "savings_enrollments"
  add_foreign_key "challenge_reminders", "users", column: "participant_user_id"
  add_foreign_key "challenge_sponsor_exports", "cohorts"
  add_foreign_key "challenge_sponsor_exports", "users", column: "approved_by_user_id"
  add_foreign_key "challenge_support_accesses", "challenge_support_tickets"
  add_foreign_key "challenge_support_accesses", "households"
  add_foreign_key "challenge_support_accesses", "savings_enrollments"
  add_foreign_key "challenge_support_accesses", "users", column: "participant_user_id"
  add_foreign_key "challenge_support_accesses", "users", column: "recipient_user_id"
  add_foreign_key "challenge_support_tickets", "households"
  add_foreign_key "challenge_support_tickets", "savings_enrollments"
  add_foreign_key "challenge_support_tickets", "users", column: "participant_user_id"
  add_foreign_key "challenge_support_tickets", "users", column: "recipient_user_id"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_messages", "coach_persona_versions"
  add_foreign_key "chat_messages", "cohort_releases", column: ["cohort_release_id", "cohort_id"], primary_key: ["id", "cohort_id"], name: "fk_chat_messages_release_cohort", on_delete: :restrict
  add_foreign_key "chat_messages", "cohort_releases", on_delete: :restrict
  add_foreign_key "chat_messages", "cohorts", on_delete: :restrict
  add_foreign_key "chat_sessions", "cohorts", on_delete: :restrict
  add_foreign_key "chat_sessions", "households"
  add_foreign_key "chat_sessions", "users"
  add_foreign_key "coach_content_citations", "chat_messages", on_delete: :cascade
  add_foreign_key "coach_content_citations", "coach_content_item_versions"
  add_foreign_key "coach_content_citations", "coach_content_pack_versions"
  add_foreign_key "coach_content_item_draft_provenances", "coach_content_items"
  add_foreign_key "coach_content_item_draft_provenances", "coach_content_source_attempts"
  add_foreign_key "coach_content_item_draft_provenances", "coach_content_source_candidates"
  add_foreign_key "coach_content_item_draft_provenances", "coach_content_sources"
  add_foreign_key "coach_content_item_draft_provenances", "users", column: "accepted_by_user_id"
  add_foreign_key "coach_content_item_version_provenances", "coach_content_item_versions"
  add_foreign_key "coach_content_item_version_provenances", "coach_content_source_attempts"
  add_foreign_key "coach_content_item_version_provenances", "coach_content_source_candidates"
  add_foreign_key "coach_content_item_version_provenances", "coach_content_sources"
  add_foreign_key "coach_content_item_version_provenances", "users", column: "accepted_by_user_id"
  add_foreign_key "coach_content_item_versions", "coach_content_items"
  add_foreign_key "coach_content_item_versions", "users", column: "approved_by_user_id"
  add_foreign_key "coach_content_items", "coach_content_item_versions", column: "current_approved_version_id"
  add_foreign_key "coach_content_items", "coach_workspaces"
  add_foreign_key "coach_content_items", "users", column: "created_by_user_id"
  add_foreign_key "coach_content_pack_draft_entries", "coach_content_item_versions"
  add_foreign_key "coach_content_pack_draft_entries", "coach_content_packs"
  add_foreign_key "coach_content_pack_version_entries", "coach_content_item_versions"
  add_foreign_key "coach_content_pack_version_entries", "coach_content_pack_versions"
  add_foreign_key "coach_content_pack_versions", "coach_content_packs"
  add_foreign_key "coach_content_pack_versions", "users", column: "published_by_user_id"
  add_foreign_key "coach_content_packs", "coach_content_pack_versions", column: "current_published_version_id"
  add_foreign_key "coach_content_packs", "coach_workspaces"
  add_foreign_key "coach_content_packs", "users", column: "created_by_user_id"
  add_foreign_key "coach_content_source_attempts", "coach_content_sources"
  add_foreign_key "coach_content_source_candidates", "coach_content_items", column: "accepted_content_item_id"
  add_foreign_key "coach_content_source_candidates", "coach_content_source_attempts"
  add_foreign_key "coach_content_source_candidates", "coach_content_sources"
  add_foreign_key "coach_content_source_candidates", "users", column: "reviewed_by_user_id"
  add_foreign_key "coach_content_source_url_intake_attempts", "coach_content_source_url_intakes", on_delete: :cascade
  add_foreign_key "coach_content_source_url_intakes", "coach_content_sources"
  add_foreign_key "coach_content_source_url_intakes", "coach_workspaces"
  add_foreign_key "coach_content_source_url_intakes", "users", column: "created_by_user_id"
  add_foreign_key "coach_content_sources", "coach_content_source_attempts", column: "current_attempt_id"
  add_foreign_key "coach_content_sources", "coach_workspaces"
  add_foreign_key "coach_content_sources", "users", column: "created_by_user_id"
  add_foreign_key "coach_content_sources", "users", column: "source_deleted_by_user_id"
  add_foreign_key "coach_operation_executions", "coach_workspaces", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohort_releases", column: ["cohort_release_id", "actor_user_id", "actor_role_snapshot"], primary_key: ["id", "released_by_user_id", "actor_role_snapshot"], name: "fk_coach_operations_release_actor", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohort_releases", column: ["cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_coach_operations_release", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohort_releases", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohort_rollout_transitions", column: ["cohort_rollout_transition_id", "actor_user_id", "actor_role_snapshot"], primary_key: ["id", "actor_user_id", "actor_role_snapshot"], name: "fk_coach_operations_rollout_transition_actor", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohort_rollout_transitions", column: ["cohort_rollout_transition_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_coach_operations_rollout_transition", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohort_rollout_transitions", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohorts", column: ["cohort_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_coach_operations_cohort_workspace", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "cohorts", on_delete: :restrict
  add_foreign_key "coach_operation_executions", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "coach_persona_behavioral_preview_evidences", "coach_persona_release_candidates"
  add_foreign_key "coach_persona_behavioral_preview_evidences", "users", column: "generated_by_user_id"
  add_foreign_key "coach_persona_draft_content_packs", "coach_content_pack_versions"
  add_foreign_key "coach_persona_draft_content_packs", "coach_personas"
  add_foreign_key "coach_persona_draft_restore_events", "coach_persona_versions", column: "source_version_id"
  add_foreign_key "coach_persona_draft_restore_events", "coach_personas"
  add_foreign_key "coach_persona_draft_restore_events", "users", column: "actor_user_id"
  add_foreign_key "coach_persona_evaluation_approvals", "coach_persona_evaluation_runs"
  add_foreign_key "coach_persona_evaluation_approvals", "users", column: "reviewed_by_user_id"
  add_foreign_key "coach_persona_evaluation_cases", "coach_personas"
  add_foreign_key "coach_persona_evaluation_cases", "coach_workspaces"
  add_foreign_key "coach_persona_evaluation_cases", "users", column: "created_by_user_id"
  add_foreign_key "coach_persona_evaluation_cases", "users", column: "retired_by_user_id"
  add_foreign_key "coach_persona_evaluation_results", "coach_persona_evaluation_cases"
  add_foreign_key "coach_persona_evaluation_results", "coach_persona_evaluation_runs"
  add_foreign_key "coach_persona_evaluation_runs", "coach_persona_release_candidates"
  add_foreign_key "coach_persona_evaluation_runs", "users", column: "requested_by_user_id"
  add_foreign_key "coach_persona_phrase_promotions", "coach_personas"
  add_foreign_key "coach_persona_phrase_promotions", "coach_phrase_attestations"
  add_foreign_key "coach_persona_phrase_promotions", "coach_phrase_proposals"
  add_foreign_key "coach_persona_phrase_promotions", "users", column: "promoted_by_user_id"
  add_foreign_key "coach_persona_publication_events", "coach_persona_versions"
  add_foreign_key "coach_persona_publication_events", "coach_persona_versions", column: "source_version_id"
  add_foreign_key "coach_persona_publication_events", "coach_personas"
  add_foreign_key "coach_persona_publication_events", "users", column: "actor_user_id"
  add_foreign_key "coach_persona_release_candidates", "coach_personas"
  add_foreign_key "coach_persona_release_candidates", "users", column: "created_by_user_id"
  add_foreign_key "coach_persona_setup_proposals", "coach_persona_setup_sessions"
  add_foreign_key "coach_persona_setup_proposals", "coach_persona_setup_turns"
  add_foreign_key "coach_persona_setup_proposals", "coach_persona_setup_turns", column: ["coach_persona_setup_turn_id", "coach_persona_setup_session_id"], primary_key: ["id", "coach_persona_setup_session_id"], name: "fk_persona_setup_proposal_turn_session"
  add_foreign_key "coach_persona_setup_proposals", "users", column: "resolved_by_user_id"
  add_foreign_key "coach_persona_setup_sessions", "coach_personas"
  add_foreign_key "coach_persona_setup_sessions", "coach_personas", column: ["coach_persona_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_persona_setup_session_persona_workspace"
  add_foreign_key "coach_persona_setup_sessions", "coach_workspaces"
  add_foreign_key "coach_persona_setup_sessions", "users", column: "created_by_user_id"
  add_foreign_key "coach_persona_setup_turns", "coach_persona_setup_sessions"
  add_foreign_key "coach_persona_version_content_packs", "coach_content_pack_versions"
  add_foreign_key "coach_persona_version_content_packs", "coach_persona_versions"
  add_foreign_key "coach_persona_version_phrase_artifacts", "coach_persona_phrase_promotions"
  add_foreign_key "coach_persona_version_phrase_artifacts", "coach_persona_versions"
  add_foreign_key "coach_persona_versions", "coach_persona_behavioral_preview_evidences"
  add_foreign_key "coach_persona_versions", "coach_persona_evaluation_approvals"
  add_foreign_key "coach_persona_versions", "coach_persona_evaluation_runs"
  add_foreign_key "coach_persona_versions", "coach_persona_release_candidates"
  add_foreign_key "coach_persona_versions", "coach_persona_versions", column: "source_version_id"
  add_foreign_key "coach_persona_versions", "coach_personas"
  add_foreign_key "coach_persona_versions", "users", column: "published_by_user_id"
  add_foreign_key "coach_personas", "coach_persona_versions", column: "current_published_version_id"
  add_foreign_key "coach_personas", "coach_workspaces"
  add_foreign_key "coach_personas", "users", column: "created_by_user_id"
  add_foreign_key "coach_phrase_attestations", "coach_phrase_proposals"
  add_foreign_key "coach_phrase_attestations", "users", column: "reviewed_by_user_id"
  add_foreign_key "coach_phrase_audience_attestations", "coach_persona_release_candidates"
  add_foreign_key "coach_phrase_audience_attestations", "users", column: "reviewed_by_user_id"
  add_foreign_key "coach_phrase_proposals", "coach_content_item_versions"
  add_foreign_key "coach_phrase_proposals", "coach_content_source_attempts"
  add_foreign_key "coach_phrase_proposals", "coach_content_source_candidates"
  add_foreign_key "coach_phrase_proposals", "coach_content_sources"
  add_foreign_key "coach_phrase_proposals", "coach_workspaces"
  add_foreign_key "coach_phrase_proposals", "users", column: "proposed_by_user_id"
  add_foreign_key "coach_profiles", "coach_workspaces", on_delete: :cascade
  add_foreign_key "coach_profiles", "users", column: "last_edited_by_user_id", on_delete: :nullify
  add_foreign_key "coach_workspace_domain_events", "coach_workspace_domains", column: ["coach_workspace_domain_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_workspace_domain_events_domain", on_delete: :restrict
  add_foreign_key "coach_workspace_domain_events", "users", column: "actor_user_id"
  add_foreign_key "coach_workspace_domains", "coach_workspaces"
  add_foreign_key "coach_workspace_domains", "users", column: "created_by_user_id"
  add_foreign_key "coach_workspace_domains", "users", column: "updated_by_user_id"
  add_foreign_key "coach_workspace_membership_events", "coach_workspaces"
  add_foreign_key "coach_workspace_membership_events", "users", column: "actor_user_id"
  add_foreign_key "coach_workspace_membership_events", "users", column: "subject_user_id"
  add_foreign_key "coach_workspace_memberships", "coach_workspaces", on_delete: :cascade
  add_foreign_key "coach_workspace_memberships", "users", on_delete: :cascade
  add_foreign_key "coach_workspaces", "users", column: "created_by_user_id", on_delete: :cascade
  add_foreign_key "cohort_experience_configurations", "coach_workspaces"
  add_foreign_key "cohort_experience_configurations", "cohort_experience_versions", column: "current_published_version_id"
  add_foreign_key "cohort_experience_configurations", "cohorts"
  add_foreign_key "cohort_experience_configurations", "cohorts", column: ["cohort_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_experience_configuration_workspace"
  add_foreign_key "cohort_experience_configurations", "users", column: "last_edited_by_user_id"
  add_foreign_key "cohort_experience_publication_events", "cohort_experience_configurations"
  add_foreign_key "cohort_experience_publication_events", "cohort_experience_versions"
  add_foreign_key "cohort_experience_publication_events", "cohort_experience_versions", column: "source_version_id"
  add_foreign_key "cohort_experience_publication_events", "users", column: "actor_user_id"
  add_foreign_key "cohort_experience_versions", "cohort_experience_configurations"
  add_foreign_key "cohort_experience_versions", "cohort_experience_versions", column: "source_version_id"
  add_foreign_key "cohort_experience_versions", "users", column: "published_by_user_id"
  add_foreign_key "cohort_memberships", "cohorts"
  add_foreign_key "cohort_memberships", "users"
  add_foreign_key "cohort_persona_assignments", "coach_persona_versions"
  add_foreign_key "cohort_persona_assignments", "coach_persona_versions", column: ["coach_persona_version_id", "coach_persona_id"], primary_key: ["id", "coach_persona_id"], name: "fk_persona_assignment_version_persona"
  add_foreign_key "cohort_persona_assignments", "coach_personas"
  add_foreign_key "cohort_persona_assignments", "coach_personas", column: ["coach_persona_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_persona_assignment_persona_workspace"
  add_foreign_key "cohort_persona_assignments", "coach_workspaces"
  add_foreign_key "cohort_persona_assignments", "cohorts"
  add_foreign_key "cohort_persona_assignments", "cohorts", column: ["cohort_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_persona_assignment_cohort_workspace"
  add_foreign_key "cohort_persona_assignments", "users", column: "assigned_by_user_id"
  add_foreign_key "cohort_release_activation_events", "coach_workspaces", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_releases", column: "from_cohort_release_id", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_releases", column: "to_cohort_release_id", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_releases", column: ["from_cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_release_activation_events_from", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_releases", column: ["to_cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_release_activation_events_to", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_rollout_transitions", column: ["cohort_rollout_transition_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_release_activation_events_transition", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_rollout_transitions", column: ["cohort_rollout_transition_id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], name: "fk_release_activation_events_rollout_transition", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_rollout_transitions", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_rollouts", column: ["cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_release_activation_events_rollout", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohort_rollouts", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohorts", column: ["cohort_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_release_activation_events_cohort", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "cohorts", on_delete: :restrict
  add_foreign_key "cohort_release_activation_events", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "coach_workspaces", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_releases", column: ["cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_release_exposures_release", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_releases", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_rollout_transitions", column: ["cohort_rollout_transition_id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_release_exposures_transition", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_rollout_transitions", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_rollout_waves", column: "cohort_rollout_wave_id", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_rollout_waves", column: ["cohort_rollout_wave_id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_release_exposures_wave", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_rollouts", column: ["cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_release_exposures_rollout", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohort_rollouts", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohorts", column: ["cohort_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_cohort_release_exposures_cohort", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "cohorts", on_delete: :restrict
  add_foreign_key "cohort_release_exposures", "users", on_delete: :restrict
  add_foreign_key "cohort_releases", "coach_persona_versions", column: ["coach_persona_version_id", "coach_persona_id"], primary_key: ["id", "coach_persona_id"], name: "fk_cohort_releases_persona_version", on_delete: :restrict
  add_foreign_key "cohort_releases", "coach_persona_versions", on_delete: :restrict
  add_foreign_key "cohort_releases", "coach_personas", column: ["coach_persona_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_cohort_releases_persona_workspace", on_delete: :restrict
  add_foreign_key "cohort_releases", "coach_personas", on_delete: :restrict
  add_foreign_key "cohort_releases", "coach_workspaces", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohort_experience_configurations", column: ["cohort_experience_configuration_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_releases_experience_configuration", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohort_experience_configurations", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohort_experience_versions", column: ["cohort_experience_version_id", "cohort_experience_configuration_id"], primary_key: ["id", "cohort_experience_configuration_id"], name: "fk_cohort_releases_experience_version", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohort_experience_versions", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohort_releases", column: "source_release_id", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohort_releases", column: ["source_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_releases_source", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohorts", column: ["cohort_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_cohort_releases_cohort_workspace", on_delete: :restrict
  add_foreign_key "cohort_releases", "cohorts", on_delete: :restrict
  add_foreign_key "cohort_releases", "users", column: "released_by_user_id", on_delete: :restrict
  add_foreign_key "cohort_releases", "workspace_brand_versions", column: ["workspace_brand_version_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_cohort_releases_brand_version", on_delete: :restrict
  add_foreign_key "cohort_releases", "workspace_brand_versions", on_delete: :restrict
  add_foreign_key "cohort_rollout_participants", "coach_workspaces", on_delete: :restrict
  add_foreign_key "cohort_rollout_participants", "cohort_rollout_waves", column: "cohort_rollout_wave_id", on_delete: :restrict
  add_foreign_key "cohort_rollout_participants", "cohort_rollout_waves", column: ["cohort_rollout_wave_id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_rollout_id", "cohort_id", "coach_workspace_id"], name: "fk_rollout_participants_wave", on_delete: :restrict
  add_foreign_key "cohort_rollout_participants", "cohort_rollouts", column: ["cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_rollout_participants_rollout", on_delete: :restrict
  add_foreign_key "cohort_rollout_participants", "cohort_rollouts", on_delete: :restrict
  add_foreign_key "cohort_rollout_participants", "cohorts", on_delete: :restrict
  add_foreign_key "cohort_rollout_participants", "users", on_delete: :restrict
  add_foreign_key "cohort_rollout_transitions", "coach_workspaces", on_delete: :restrict
  add_foreign_key "cohort_rollout_transitions", "cohort_releases", column: "rollback_cohort_release_id", on_delete: :restrict
  add_foreign_key "cohort_rollout_transitions", "cohort_releases", column: ["rollback_cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_rollout_transitions_rollback_release", on_delete: :restrict
  add_foreign_key "cohort_rollout_transitions", "cohort_rollouts", column: ["cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_rollout_transitions_rollout", on_delete: :restrict
  add_foreign_key "cohort_rollout_transitions", "cohort_rollouts", on_delete: :restrict
  add_foreign_key "cohort_rollout_transitions", "cohorts", on_delete: :restrict
  add_foreign_key "cohort_rollout_transitions", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "cohort_rollout_waves", "coach_workspaces", on_delete: :restrict
  add_foreign_key "cohort_rollout_waves", "cohort_rollouts", column: ["cohort_rollout_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_rollout_waves_rollout", on_delete: :restrict
  add_foreign_key "cohort_rollout_waves", "cohort_rollouts", on_delete: :restrict
  add_foreign_key "cohort_rollout_waves", "cohorts", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "coach_workspaces", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohort_releases", column: "baseline_cohort_release_id", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohort_releases", column: "rollback_cohort_release_id", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohort_releases", column: "target_cohort_release_id", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohort_releases", column: ["baseline_cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_rollouts_baseline_release", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohort_releases", column: ["rollback_cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_rollouts_rollback_release", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohort_releases", column: ["target_cohort_release_id", "cohort_id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohort_rollouts_target_release", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohorts", column: ["cohort_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_cohort_rollouts_cohort_workspace", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "cohorts", on_delete: :restrict
  add_foreign_key "cohort_rollouts", "users", column: "planned_by_user_id", on_delete: :restrict
  add_foreign_key "cohorts", "coach_workspaces"
  add_foreign_key "cohorts", "cohort_releases", column: "active_cohort_release_id", on_delete: :restrict
  add_foreign_key "cohorts", "cohort_releases", column: ["active_cohort_release_id", "id", "coach_workspace_id"], primary_key: ["id", "cohort_id", "coach_workspace_id"], name: "fk_cohorts_active_release_scope", on_delete: :restrict
  add_foreign_key "cohorts", "users", column: "created_by_user_id"
  add_foreign_key "debts", "households"
  add_foreign_key "enterprise_audit_events", "enterprise_organizations"
  add_foreign_key "enterprise_audit_events", "users", column: "actor_user_id"
  add_foreign_key "enterprise_cohort_grants", "cohort_memberships", on_delete: :cascade
  add_foreign_key "enterprise_cohort_grants", "enterprise_memberships"
  add_foreign_key "enterprise_directory_group_memberships", "enterprise_directory_users"
  add_foreign_key "enterprise_directory_users", "enterprise_memberships"
  add_foreign_key "enterprise_directory_users", "enterprise_organizations"
  add_foreign_key "enterprise_group_mappings", "cohorts"
  add_foreign_key "enterprise_group_mappings", "enterprise_organizations"
  add_foreign_key "enterprise_memberships", "enterprise_organizations"
  add_foreign_key "enterprise_memberships", "users"
  add_foreign_key "enterprise_organizations", "coach_workspaces"
  add_foreign_key "expense_items", "households"
  add_foreign_key "financial_baseline_heads", "financial_baseline_versions", column: ["approved_version_id", "id", "household_id"], primary_key: ["id", "financial_baseline_head_id", "household_id"], name: "financial_baseline_approved_head_scope"
  add_foreign_key "financial_baseline_heads", "households"
  add_foreign_key "financial_baseline_heads", "users", column: "participant_user_id"
  add_foreign_key "financial_baseline_versions", "financial_baseline_heads"
  add_foreign_key "financial_baseline_versions", "financial_baseline_heads", column: ["financial_baseline_head_id", "approved_by_user_id", "household_id"], primary_key: ["id", "participant_user_id", "household_id"], name: "financial_baseline_version_actual_participant"
  add_foreign_key "financial_baseline_versions", "financial_baseline_heads", column: ["financial_baseline_head_id", "household_id"], primary_key: ["id", "household_id"], name: "financial_baseline_version_household_scope"
  add_foreign_key "financial_baseline_versions", "financial_baseline_versions", column: ["supersedes_id", "financial_baseline_head_id", "household_id"], primary_key: ["id", "financial_baseline_head_id", "household_id"], name: "financial_baseline_supersedes_head_scope"
  add_foreign_key "financial_baseline_versions", "households"
  add_foreign_key "financial_baseline_versions", "users", column: "approved_by_user_id"
  add_foreign_key "financial_document_extraction_dispatches", "financial_document_imports", on_delete: :nullify
  add_foreign_key "financial_document_import_attempts", "financial_document_imports"
  add_foreign_key "financial_document_import_items", "financial_document_imports"
  add_foreign_key "financial_document_import_items", "users", column: "applied_by_user_id"
  add_foreign_key "financial_document_imports", "households"
  add_foreign_key "financial_document_imports", "users", column: "applied_by_user_id"
  add_foreign_key "financial_document_imports", "users", column: "source_deleted_by_user_id"
  add_foreign_key "financial_document_imports", "users", column: "uploaded_by_user_id"
  add_foreign_key "financial_document_source_cleanups", "financial_document_imports", on_delete: :nullify
  add_foreign_key "financial_document_source_cleanups", "households", on_delete: :nullify
  add_foreign_key "financial_document_source_cleanups", "users", column: "requested_by_user_id", on_delete: :nullify
  add_foreign_key "financial_extraction_revisions", "financial_document_import_attempts", on_delete: :nullify
  add_foreign_key "financial_extraction_revisions", "financial_document_imports", on_delete: :nullify
  add_foreign_key "financial_extraction_revisions", "households"
  add_foreign_key "financial_restart_reviews", "cohorts"
  add_foreign_key "financial_restart_reviews", "households"
  add_foreign_key "financial_restart_reviews", "setup_support_requests"
  add_foreign_key "financial_restart_reviews", "users", column: "requested_by_user_id"
  add_foreign_key "financial_source_accounts", "financial_extraction_revisions"
  add_foreign_key "financial_source_accounts", "financial_extraction_revisions", column: ["financial_extraction_revision_id", "household_id"], primary_key: ["id", "household_id"], name: "source_accounts_revision_household_fk"
  add_foreign_key "financial_source_accounts", "households"
  add_foreign_key "financial_source_events", "financial_extraction_revisions"
  add_foreign_key "financial_source_events", "financial_source_accounts"
  add_foreign_key "financial_source_events", "financial_source_accounts", column: ["financial_source_account_id", "financial_extraction_revision_id", "household_id"], primary_key: ["id", "financial_extraction_revision_id", "household_id"], name: "source_events_account_revision_household_fk"
  add_foreign_key "financial_source_events", "households"
  add_foreign_key "financial_source_evidences", "financial_source_accounts", column: ["financial_source_account_id", "household_id"], primary_key: ["id", "household_id"], name: "source_evidence_account_household_fk", on_delete: :cascade
  add_foreign_key "financial_source_evidences", "financial_source_accounts", on_delete: :cascade
  add_foreign_key "financial_source_evidences", "financial_source_events", column: ["financial_source_event_id", "household_id"], primary_key: ["id", "household_id"], name: "source_evidence_event_household_fk", on_delete: :cascade
  add_foreign_key "financial_source_evidences", "financial_source_events", on_delete: :cascade
  add_foreign_key "financial_source_evidences", "households"
  add_foreign_key "financial_source_uses", "financial_document_imports", on_delete: :nullify
  add_foreign_key "financial_source_uses", "households"
  add_foreign_key "financial_source_uses", "savings_enrollments"
  add_foreign_key "financial_source_uses", "users", column: "participant_user_id"
  add_foreign_key "goals", "households"
  add_foreign_key "household_audit_events", "households"
  add_foreign_key "household_audit_events", "users"
  add_foreign_key "household_memberships", "households"
  add_foreign_key "household_memberships", "users"
  add_foreign_key "household_memories", "chat_messages", column: "source_chat_message_id", on_delete: :nullify
  add_foreign_key "household_memories", "households"
  add_foreign_key "household_memories", "users", column: "owner_user_id"
  add_foreign_key "household_operation_executions", "household_audit_events"
  add_foreign_key "household_operation_executions", "households"
  add_foreign_key "household_operation_executions", "users"
  add_foreign_key "household_profiles", "households"
  add_foreign_key "household_transactions", "budget_periods"
  add_foreign_key "household_transactions", "financial_document_imports", column: "source_import_id"
  add_foreign_key "household_transactions", "financial_source_events", column: ["financial_source_event_id", "household_id"], primary_key: ["id", "household_id"], name: "source_transactions_event_household_fk"
  add_foreign_key "household_transactions", "financial_source_events", on_delete: :nullify
  add_foreign_key "household_transactions", "households"
  add_foreign_key "households", "users", column: "created_by_user_id"
  add_foreign_key "income_schedule_entries", "income_sources", on_delete: :cascade
  add_foreign_key "income_sources", "households"
  add_foreign_key "invitation_email_attempts", "users"
  add_foreign_key "invitation_email_attempts", "users", column: "sent_by_user_id"
  add_foreign_key "merchant_category_rules", "budget_categories"
  add_foreign_key "merchant_category_rules", "households"
  add_foreign_key "mia_action_draft_applications", "households"
  add_foreign_key "mia_action_draft_applications", "mia_action_drafts"
  add_foreign_key "mia_action_draft_applications", "mia_action_drafts", column: ["mia_action_draft_id", "household_id"], primary_key: ["id", "household_id"], name: "fk_mia_plan_applications_draft_household"
  add_foreign_key "mia_action_draft_applications", "users"
  add_foreign_key "mia_action_drafts", "chat_messages", column: "assistant_chat_message_id"
  add_foreign_key "mia_action_drafts", "chat_messages", column: "source_chat_message_id"
  add_foreign_key "mia_action_drafts", "households"
  add_foreign_key "mia_action_drafts", "users", column: "applied_by_user_id"
  add_foreign_key "mia_action_drafts", "users", column: "canceled_by_user_id"
  add_foreign_key "mia_action_drafts", "users", column: "requested_by_user_id"
  add_foreign_key "mia_action_items", "mia_action_drafts"
  add_foreign_key "mia_action_items", "users", column: "canceled_by_user_id"
  add_foreign_key "mia_message_requests", "chat_sessions"
  add_foreign_key "pilot_feedback_reports", "households"
  add_foreign_key "pilot_feedback_reports", "users"
  add_foreign_key "plaid_accounts", "plaid_items"
  add_foreign_key "plaid_items", "households"
  add_foreign_key "plaid_items", "users", column: "connected_by_user_id"
  add_foreign_key "plaid_transactions", "plaid_accounts"
  add_foreign_key "plaid_transactions", "plaid_items"
  add_foreign_key "plaid_transactions", "transaction_drafts", on_delete: :nullify
  add_foreign_key "savings_checkpoint_drafts", "savings_checkpoint_versions", column: ["approved_version_id", "savings_checkpoint_id"], primary_key: ["id", "savings_checkpoint_id"], name: "savings_checkpoint_drafts_approved_version_id", on_delete: :restrict
  add_foreign_key "savings_checkpoint_drafts", "savings_checkpoint_versions", column: ["base_version_id", "savings_checkpoint_id"], primary_key: ["id", "savings_checkpoint_id"], name: "savings_checkpoint_drafts_base_version_id", on_delete: :restrict
  add_foreign_key "savings_checkpoint_drafts", "savings_checkpoints"
  add_foreign_key "savings_checkpoint_drafts", "savings_checkpoints", column: ["savings_checkpoint_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_checkpoint_drafts_scope", on_delete: :restrict
  add_foreign_key "savings_checkpoint_drafts", "savings_enrollments"
  add_foreign_key "savings_checkpoint_drafts", "users", column: "created_by_user_id"
  add_foreign_key "savings_checkpoint_versions", "savings_checkpoint_versions", column: ["previous_version_id", "savings_checkpoint_id"], primary_key: ["id", "savings_checkpoint_id"], name: "savings_checkpoint_versions_previous_scope", on_delete: :restrict
  add_foreign_key "savings_checkpoint_versions", "savings_checkpoints"
  add_foreign_key "savings_checkpoint_versions", "savings_checkpoints", column: ["savings_checkpoint_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_checkpoint_versions_parent_scope", on_delete: :restrict
  add_foreign_key "savings_checkpoint_versions", "savings_enrollments"
  add_foreign_key "savings_checkpoint_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_checkpoints", "savings_checkpoint_versions", column: ["current_version_id", "id"], primary_key: ["id", "savings_checkpoint_id"], name: "savings_checkpoints_current_scope", on_delete: :restrict
  add_foreign_key "savings_checkpoints", "savings_enrollments"
  add_foreign_key "savings_daily_check_in_versions", "savings_daily_check_in_versions", column: ["previous_version_id", "savings_daily_check_in_id"], primary_key: ["id", "savings_daily_check_in_id"], name: "savings_daily_check_in_versions_previous_scope", on_delete: :restrict
  add_foreign_key "savings_daily_check_in_versions", "savings_daily_check_ins"
  add_foreign_key "savings_daily_check_in_versions", "savings_daily_check_ins", column: ["savings_daily_check_in_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_daily_check_in_versions_parent_scope", on_delete: :restrict
  add_foreign_key "savings_daily_check_in_versions", "savings_enrollments"
  add_foreign_key "savings_daily_check_in_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_daily_check_ins", "savings_daily_check_in_versions", column: ["current_version_id", "id"], primary_key: ["id", "savings_daily_check_in_id"], name: "savings_daily_check_ins_current_scope", on_delete: :restrict
  add_foreign_key "savings_daily_check_ins", "savings_enrollments"
  add_foreign_key "savings_daily_ledgers", "savings_enrollments"
  add_foreign_key "savings_daily_purchase_drafts", "household_transactions", column: "linked_transaction_id"
  add_foreign_key "savings_daily_purchase_drafts", "savings_daily_purchase_versions", column: ["approved_version_id", "savings_daily_purchase_id"], primary_key: ["id", "savings_daily_purchase_id"], name: "savings_daily_purchase_drafts_approved_version_id", on_delete: :restrict
  add_foreign_key "savings_daily_purchase_drafts", "savings_daily_purchase_versions", column: ["base_version_id", "savings_daily_purchase_id"], primary_key: ["id", "savings_daily_purchase_id"], name: "savings_daily_purchase_drafts_base_version_id", on_delete: :restrict
  add_foreign_key "savings_daily_purchase_drafts", "savings_daily_purchases"
  add_foreign_key "savings_daily_purchase_drafts", "savings_daily_purchases", column: ["savings_daily_purchase_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_daily_purchase_drafts_scope", on_delete: :restrict
  add_foreign_key "savings_daily_purchase_drafts", "savings_enrollments"
  add_foreign_key "savings_daily_purchase_drafts", "users", column: "created_by_user_id"
  add_foreign_key "savings_daily_purchase_versions", "household_transactions"
  add_foreign_key "savings_daily_purchase_versions", "savings_daily_purchase_versions", column: ["previous_version_id", "savings_daily_purchase_id"], primary_key: ["id", "savings_daily_purchase_id"], name: "savings_daily_purchase_versions_previous_scope", on_delete: :restrict
  add_foreign_key "savings_daily_purchase_versions", "savings_daily_purchases"
  add_foreign_key "savings_daily_purchase_versions", "savings_daily_purchases", column: ["savings_daily_purchase_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_daily_purchase_versions_parent_scope", on_delete: :restrict
  add_foreign_key "savings_daily_purchase_versions", "savings_enrollments"
  add_foreign_key "savings_daily_purchase_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_daily_purchases", "savings_daily_purchase_versions", column: ["current_version_id", "id"], primary_key: ["id", "savings_daily_purchase_id"], name: "savings_daily_purchases_current_scope", on_delete: :restrict
  add_foreign_key "savings_daily_purchases", "savings_enrollments"
  add_foreign_key "savings_daily_reflection_versions", "savings_daily_reflection_versions", column: ["previous_version_id", "savings_daily_reflection_id"], primary_key: ["id", "savings_daily_reflection_id"], name: "savings_daily_reflection_versions_previous_scope", on_delete: :restrict
  add_foreign_key "savings_daily_reflection_versions", "savings_daily_reflections"
  add_foreign_key "savings_daily_reflection_versions", "savings_daily_reflections", column: ["savings_daily_reflection_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_daily_reflection_versions_parent_scope", on_delete: :restrict
  add_foreign_key "savings_daily_reflection_versions", "savings_enrollments"
  add_foreign_key "savings_daily_reflection_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_daily_reflection_versions", "users", column: "erased_by_user_id"
  add_foreign_key "savings_daily_reflections", "savings_daily_purchases"
  add_foreign_key "savings_daily_reflections", "savings_daily_purchases", column: ["savings_daily_purchase_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "daily_reflection_purchase_scope", on_delete: :restrict
  add_foreign_key "savings_daily_reflections", "savings_daily_reflection_versions", column: ["current_version_id", "id"], primary_key: ["id", "savings_daily_reflection_id"], name: "savings_daily_reflections_current_scope", on_delete: :restrict
  add_foreign_key "savings_daily_reflections", "savings_enrollments"
  add_foreign_key "savings_debt_cards", "debts", column: "household_debt_id"
  add_foreign_key "savings_debt_cards", "households"
  add_foreign_key "savings_debt_cards", "savings_debt_versions", column: ["current_version_id", "id"], primary_key: ["id", "savings_debt_card_id"], name: "savings_debt_current_scope"
  add_foreign_key "savings_debt_cards", "savings_enrollments"
  add_foreign_key "savings_debt_cards", "source_tracked_accounts"
  add_foreign_key "savings_debt_cards", "users"
  add_foreign_key "savings_debt_drafts", "debts", column: "household_debt_id"
  add_foreign_key "savings_debt_drafts", "savings_debt_cards"
  add_foreign_key "savings_debt_drafts", "savings_debt_versions", column: ["approved_version_id", "savings_debt_card_id"], primary_key: ["id", "savings_debt_card_id"], name: "savings_debt_approved_scope"
  add_foreign_key "savings_debt_drafts", "savings_debt_versions", column: ["base_version_id", "savings_debt_card_id"], primary_key: ["id", "savings_debt_card_id"], name: "savings_debt_base_scope"
  add_foreign_key "savings_debt_drafts", "savings_enrollments"
  add_foreign_key "savings_debt_drafts", "source_account_identity_versions"
  add_foreign_key "savings_debt_drafts", "source_revision_approvals"
  add_foreign_key "savings_debt_drafts", "source_tracked_accounts"
  add_foreign_key "savings_debt_drafts", "users", column: "created_by_user_id"
  add_foreign_key "savings_debt_versions", "debts", column: "household_debt_id"
  add_foreign_key "savings_debt_versions", "savings_debt_cards"
  add_foreign_key "savings_debt_versions", "savings_debt_versions", column: ["previous_version_id", "savings_debt_card_id"], primary_key: ["id", "savings_debt_card_id"], name: "savings_debt_previous_scope"
  add_foreign_key "savings_debt_versions", "savings_enrollments"
  add_foreign_key "savings_debt_versions", "source_account_identity_versions"
  add_foreign_key "savings_debt_versions", "source_revision_approvals"
  add_foreign_key "savings_debt_versions", "source_tracked_accounts"
  add_foreign_key "savings_debt_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_enrollments", "cohort_releases", column: "accepted_cohort_release_id"
  add_foreign_key "savings_enrollments", "cohorts"
  add_foreign_key "savings_enrollments", "households"
  add_foreign_key "savings_enrollments", "savings_plan_versions", column: ["current_accepted_plan_version_id", "id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_enrollment_plan_scope", on_delete: :restrict
  add_foreign_key "savings_enrollments", "users"
  add_foreign_key "savings_entries", "savings_enrollments"
  add_foreign_key "savings_entries", "savings_entry_versions", column: ["current_approved_version_id", "id"], primary_key: ["id", "savings_entry_id"], name: "savings_entry_head_scope", on_delete: :restrict
  add_foreign_key "savings_entry_drafts", "savings_entries"
  add_foreign_key "savings_entry_drafts", "savings_entry_versions", column: ["approved_version_id", "savings_entry_id"], primary_key: ["id", "savings_entry_id"], name: "savings_draft_approved_version_id_scope", on_delete: :restrict
  add_foreign_key "savings_entry_drafts", "savings_entry_versions", column: ["base_version_id", "savings_entry_id"], primary_key: ["id", "savings_entry_id"], name: "savings_draft_base_version_id_scope", on_delete: :restrict
  add_foreign_key "savings_entry_drafts", "users", column: "created_by_user_id"
  add_foreign_key "savings_entry_versions", "savings_enrollments"
  add_foreign_key "savings_entry_versions", "savings_entries"
  add_foreign_key "savings_entry_versions", "savings_entries", column: ["savings_entry_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_version_enrollment_scope", on_delete: :restrict
  add_foreign_key "savings_entry_versions", "savings_entry_versions", column: ["previous_version_id", "savings_entry_id"], primary_key: ["id", "savings_entry_id"], name: "savings_version_previous_scope", on_delete: :restrict
  add_foreign_key "savings_entry_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_evidence_allocations", "households"
  add_foreign_key "savings_evidence_allocations", "savings_enrollments"
  add_foreign_key "savings_evidence_allocations", "savings_entry_versions"
  add_foreign_key "savings_evidence_allocations", "savings_evidence_versions", column: ["current_version_id", "id"], primary_key: ["id", "savings_evidence_allocation_id"], name: "savings_evidence_head_scope"
  add_foreign_key "savings_evidence_capacities", "financial_source_events"
  add_foreign_key "savings_evidence_capacities", "savings_evidence_versions"
  add_foreign_key "savings_evidence_capacities", "source_review_versions"
  add_foreign_key "savings_evidence_versions", "savings_enrollments"
  add_foreign_key "savings_evidence_versions", "savings_evidence_allocations"
  add_foreign_key "savings_evidence_versions", "savings_evidence_versions", column: ["previous_version_id", "savings_evidence_allocation_id"], primary_key: ["id", "savings_evidence_allocation_id"], name: "savings_evidence_prior_scope"
  add_foreign_key "savings_evidence_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_plan_drafts", "financial_baseline_versions"
  add_foreign_key "savings_plan_drafts", "savings_enrollments"
  add_foreign_key "savings_plan_drafts", "savings_plan_versions", column: ["approved_plan_version_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_draft_approved_plan_version_id_scope", on_delete: :restrict
  add_foreign_key "savings_plan_drafts", "savings_plan_versions", column: ["base_plan_version_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_draft_base_plan_version_id_scope", on_delete: :restrict
  add_foreign_key "savings_plan_drafts", "users", column: "created_by_user_id"
  add_foreign_key "savings_plan_versions", "financial_baseline_versions"
  add_foreign_key "savings_plan_versions", "savings_enrollments"
  add_foreign_key "savings_plan_versions", "savings_plan_versions", column: ["previous_version_id", "savings_enrollment_id"], primary_key: ["id", "savings_enrollment_id"], name: "savings_plan_previous_scope", on_delete: :restrict
  add_foreign_key "savings_plan_versions", "users", column: "approved_by_user_id"
  add_foreign_key "savings_zero_attestations", "savings_enrollments"
  add_foreign_key "savings_zero_attestations", "savings_zero_attestations", column: "previous_attestation_id"
  add_foreign_key "savings_zero_attestations", "users", column: "approved_by_user_id"
  add_foreign_key "setup_help_request_keys", "households"
  add_foreign_key "setup_help_request_keys", "setup_support_requests"
  add_foreign_key "setup_help_request_keys", "users"
  add_foreign_key "setup_support_requests", "cohorts"
  add_foreign_key "setup_support_requests", "financial_restart_reviews"
  add_foreign_key "setup_support_requests", "households"
  add_foreign_key "setup_support_requests", "users", column: "prepared_by_user_id"
  add_foreign_key "setup_support_requests", "users", column: "requested_by_user_id"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "source_account_identity_versions", "households"
  add_foreign_key "source_account_identity_versions", "source_account_identity_versions", column: "supersedes_id"
  add_foreign_key "source_account_identity_versions", "source_account_identity_versions", column: ["supersedes_id", "source_account_review_head_id", "household_id"], primary_key: ["id", "source_account_review_head_id", "household_id"], name: "source_account_identity_versions_supersedes_head_scope"
  add_foreign_key "source_account_identity_versions", "source_account_review_heads"
  add_foreign_key "source_account_identity_versions", "source_account_review_heads", column: ["source_account_review_head_id", "household_id"], primary_key: ["id", "household_id"], name: "source_account_identity_versions_source_account_review_head_sc"
  add_foreign_key "source_account_identity_versions", "source_tracked_accounts"
  add_foreign_key "source_account_identity_versions", "source_tracked_accounts", column: ["source_tracked_account_id", "household_id"], primary_key: ["id", "household_id"], name: "source_account_identity_versions_source_tracked_account_scope"
  add_foreign_key "source_account_identity_versions", "users", column: "approved_by_user_id"
  add_foreign_key "source_account_review_heads", "financial_source_accounts"
  add_foreign_key "source_account_review_heads", "financial_source_accounts", column: ["financial_source_account_id", "household_id"], primary_key: ["id", "household_id"], name: "source_account_review_heads_financial_source_account_scope"
  add_foreign_key "source_account_review_heads", "households"
  add_foreign_key "source_account_review_heads", "source_account_identity_versions", column: ["approved_version_id", "id", "household_id"], primary_key: ["id", "source_account_review_head_id", "household_id"], name: "source_account_review_heads_approved_head_scope"
  add_foreign_key "source_economic_group_versions", "households"
  add_foreign_key "source_economic_group_versions", "source_economic_group_versions", column: "supersedes_id"
  add_foreign_key "source_economic_group_versions", "source_economic_group_versions", column: ["supersedes_id", "source_economic_group_id", "household_id"], primary_key: ["id", "source_economic_group_id", "household_id"], name: "source_economic_group_versions_supersedes_head_scope"
  add_foreign_key "source_economic_group_versions", "source_economic_groups"
  add_foreign_key "source_economic_group_versions", "source_economic_groups", column: ["source_economic_group_id", "household_id"], primary_key: ["id", "household_id"], name: "source_economic_group_versions_source_economic_group_scope"
  add_foreign_key "source_economic_group_versions", "users", column: "approved_by_user_id"
  add_foreign_key "source_economic_groups", "households"
  add_foreign_key "source_economic_groups", "source_economic_group_versions", column: ["approved_version_id", "id", "household_id"], primary_key: ["id", "source_economic_group_id", "household_id"], name: "source_economic_groups_approved_head_scope"
  add_foreign_key "source_economic_memberships", "households"
  add_foreign_key "source_economic_memberships", "source_economic_group_versions"
  add_foreign_key "source_economic_memberships", "source_economic_group_versions", column: ["source_economic_group_version_id", "household_id"], primary_key: ["id", "household_id"], name: "source_economic_memberships_source_economic_group_version_scop"
  add_foreign_key "source_economic_memberships", "source_review_versions"
  add_foreign_key "source_economic_memberships", "source_review_versions", column: ["source_review_version_id", "household_id"], primary_key: ["id", "household_id"], name: "source_economic_memberships_source_review_version_scope"
  add_foreign_key "source_projection_revisions", "household_transactions", column: "previous_transaction_id"
  add_foreign_key "source_projection_revisions", "household_transactions", column: "replacement_transaction_id"
  add_foreign_key "source_projection_revisions", "household_transactions", column: ["previous_transaction_id", "household_id"], primary_key: ["id", "household_id"], name: "source_projection_revisions_previous_transaction_scope"
  add_foreign_key "source_projection_revisions", "household_transactions", column: ["replacement_transaction_id", "household_id"], primary_key: ["id", "household_id"], name: "source_projection_revisions_replacement_transaction_scope"
  add_foreign_key "source_projection_revisions", "households"
  add_foreign_key "source_projection_revisions", "source_review_versions"
  add_foreign_key "source_projection_revisions", "source_review_versions", column: ["source_review_version_id", "household_id"], primary_key: ["id", "household_id"], name: "source_projection_revisions_source_review_version_scope"
  add_foreign_key "source_projection_revisions", "users", column: "approved_by_user_id"
  add_foreign_key "source_review_drafts", "households"
  add_foreign_key "source_review_drafts", "source_review_heads"
  add_foreign_key "source_review_drafts", "source_review_heads", column: ["source_review_head_id", "household_id"], primary_key: ["id", "household_id"], name: "source_review_drafts_source_review_head_scope"
  add_foreign_key "source_review_drafts", "source_review_versions", column: ["base_version_id", "source_review_head_id", "household_id"], primary_key: ["id", "source_review_head_id", "household_id"], name: "source_review_drafts_base_head_scope"
  add_foreign_key "source_review_drafts", "users", column: "staged_by_user_id"
  add_foreign_key "source_review_heads", "financial_source_events"
  add_foreign_key "source_review_heads", "financial_source_events", column: ["financial_source_event_id", "household_id"], primary_key: ["id", "household_id"], name: "source_review_heads_financial_source_event_scope"
  add_foreign_key "source_review_heads", "households"
  add_foreign_key "source_review_heads", "source_review_versions", column: ["approved_version_id", "id", "household_id"], primary_key: ["id", "source_review_head_id", "household_id"], name: "source_review_heads_approved_head_scope"
  add_foreign_key "source_review_versions", "budget_categories"
  add_foreign_key "source_review_versions", "budget_categories", column: ["budget_category_id", "household_id"], primary_key: ["id", "household_id"], name: "source_review_versions_budget_category_scope"
  add_foreign_key "source_review_versions", "households"
  add_foreign_key "source_review_versions", "source_account_identity_versions"
  add_foreign_key "source_review_versions", "source_account_identity_versions", column: ["source_account_identity_version_id", "household_id"], primary_key: ["id", "household_id"], name: "source_review_versions_source_account_identity_version_scope"
  add_foreign_key "source_review_versions", "source_review_heads"
  add_foreign_key "source_review_versions", "source_review_heads", column: ["source_review_head_id", "household_id"], primary_key: ["id", "household_id"], name: "source_review_versions_source_review_head_scope"
  add_foreign_key "source_review_versions", "source_review_versions", column: "supersedes_id"
  add_foreign_key "source_review_versions", "source_review_versions", column: ["matched_version_id", "household_id"], primary_key: ["id", "household_id"], name: "source_review_versions_matched_version_scope"
  add_foreign_key "source_review_versions", "source_review_versions", column: ["supersedes_id", "source_review_head_id", "household_id"], primary_key: ["id", "source_review_head_id", "household_id"], name: "source_review_versions_supersedes_head_scope"
  add_foreign_key "source_review_versions", "users", column: "approved_by_user_id"
  add_foreign_key "source_revision_approvals", "financial_extraction_revisions"
  add_foreign_key "source_revision_approvals", "financial_extraction_revisions", column: ["financial_extraction_revision_id", "household_id"], primary_key: ["id", "household_id"], name: "source_revision_approvals_financial_extraction_revision_scope"
  add_foreign_key "source_revision_approvals", "households"
  add_foreign_key "source_revision_approvals", "source_revision_approvals", column: "supersedes_id"
  add_foreign_key "source_revision_approvals", "users", column: "approved_by_user_id"
  add_foreign_key "source_tracked_accounts", "accounts", column: ["account_id", "household_id"], primary_key: ["id", "household_id"], name: "source_tracked_accounts_account_scope", deferrable: :deferred
  add_foreign_key "source_tracked_accounts", "accounts", on_delete: :nullify
  add_foreign_key "source_tracked_accounts", "households"
  add_foreign_key "source_tracked_accounts", "users", column: "approved_by_user_id"
  add_foreign_key "transaction_draft_matches", "household_transactions"
  add_foreign_key "transaction_draft_matches", "transaction_drafts"
  add_foreign_key "transaction_draft_splits", "budget_categories"
  add_foreign_key "transaction_draft_splits", "transaction_drafts"
  add_foreign_key "transaction_drafts", "budget_categories"
  add_foreign_key "transaction_drafts", "financial_document_imports"
  add_foreign_key "transaction_drafts", "financial_source_events", column: ["financial_source_event_id", "household_id"], primary_key: ["id", "household_id"], name: "source_drafts_event_household_fk"
  add_foreign_key "transaction_drafts", "financial_source_events", on_delete: :nullify
  add_foreign_key "transaction_drafts", "household_transactions", column: "confirmed_transaction_id"
  add_foreign_key "transaction_drafts", "household_transactions", column: "matched_transaction_id"
  add_foreign_key "transaction_drafts", "households"
  add_foreign_key "transaction_splits", "budget_categories"
  add_foreign_key "transaction_splits", "household_transactions"
  add_foreign_key "users", "users", column: "invited_by_user_id"
  add_foreign_key "users", "users", column: "last_invite_email_sent_by_user_id"
  add_foreign_key "workspace_brand_configurations", "coach_workspaces"
  add_foreign_key "workspace_brand_configurations", "users", column: "last_edited_by_user_id"
  add_foreign_key "workspace_brand_configurations", "workspace_brand_versions", column: ["current_published_version_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_workspace_brand_current_version", on_delete: :restrict
  add_foreign_key "workspace_brand_publication_events", "users", column: "actor_user_id"
  add_foreign_key "workspace_brand_publication_events", "workspace_brand_configurations", column: ["workspace_brand_configuration_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_workspace_brand_events_configuration", on_delete: :restrict
  add_foreign_key "workspace_brand_publication_events", "workspace_brand_versions", column: "source_version_id"
  add_foreign_key "workspace_brand_publication_events", "workspace_brand_versions", column: ["source_version_id", "workspace_brand_configuration_id"], primary_key: ["id", "workspace_brand_configuration_id"], name: "fk_workspace_brand_events_source", on_delete: :restrict
  add_foreign_key "workspace_brand_publication_events", "workspace_brand_versions", column: ["workspace_brand_version_id", "workspace_brand_configuration_id"], primary_key: ["id", "workspace_brand_configuration_id"], name: "fk_workspace_brand_events_version", on_delete: :restrict
  add_foreign_key "workspace_brand_versions", "users", column: "published_by_user_id"
  add_foreign_key "workspace_brand_versions", "workspace_brand_configurations", column: ["workspace_brand_configuration_id", "coach_workspace_id"], primary_key: ["id", "coach_workspace_id"], name: "fk_workspace_brand_versions_configuration", on_delete: :restrict
  add_foreign_key "workspace_brand_versions", "workspace_brand_versions", column: "source_version_id"
  add_foreign_key "workspace_brand_versions", "workspace_brand_versions", column: ["source_version_id", "workspace_brand_configuration_id"], primary_key: ["id", "workspace_brand_configuration_id"], name: "fk_workspace_brand_versions_source", on_delete: :restrict
  execute <<~SQL
    CREATE OR REPLACE FUNCTION public.source_review_facts_immutable()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Approved source facts cannot be deleted'; END IF;
      IF TG_TABLE_NAME = 'source_tracked_accounts' AND NEW.account_id IS NULL AND
         (to_jsonb(NEW) - 'account_id') = (to_jsonb(OLD) - 'account_id') THEN RETURN NEW; END IF;
      IF to_jsonb(NEW) <> to_jsonb(OLD) THEN RAISE EXCEPTION 'Approved source facts are immutable; append a version'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_privacy_events_immutable BEFORE DELETE OR UPDATE ON public.challenge_privacy_events FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_privacy_reads_immutable BEFORE DELETE OR UPDATE ON public.challenge_privacy_reads FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_reminder_events_immutable BEFORE DELETE OR UPDATE ON public.challenge_reminder_events FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_sponsor_exports_immutable BEFORE DELETE OR UPDATE ON public.challenge_sponsor_exports FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER financial_baseline_versions_immutable BEFORE DELETE OR UPDATE ON public.financial_baseline_versions FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_account_identity_versions_immutable BEFORE DELETE OR UPDATE ON public.source_account_identity_versions FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_economic_group_versions_immutable BEFORE DELETE OR UPDATE ON public.source_economic_group_versions FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_economic_memberships_immutable BEFORE DELETE OR UPDATE ON public.source_economic_memberships FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_projection_revisions_immutable BEFORE DELETE OR UPDATE ON public.source_projection_revisions FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_review_versions_immutable BEFORE DELETE OR UPDATE ON public.source_review_versions FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_revision_approvals_immutable BEFORE DELETE OR UPDATE ON public.source_revision_approvals FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_tracked_accounts_immutable BEFORE DELETE OR UPDATE ON public.source_tracked_accounts FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable();
  SQL
  execute <<~SQL
    CREATE OR REPLACE FUNCTION public.source_review_heads_scope_immutable()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Source review heads cannot be deleted'; END IF;
      IF (to_jsonb(NEW) - ARRAY['approved_version_id', 'lock_version', 'updated_at']) <>
         (to_jsonb(OLD) - ARRAY['approved_version_id', 'lock_version', 'updated_at']) THEN
        RAISE EXCEPTION 'Source review head identity is immutable';
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~SQL
    CREATE TRIGGER financial_baseline_heads_scope_immutable BEFORE DELETE OR UPDATE ON public.financial_baseline_heads FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_account_review_heads_scope_immutable BEFORE DELETE OR UPDATE ON public.source_account_review_heads FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_economic_groups_scope_immutable BEFORE DELETE OR UPDATE ON public.source_economic_groups FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable();
  SQL
  execute <<~SQL
    CREATE TRIGGER source_review_heads_scope_immutable BEFORE DELETE OR UPDATE ON public.source_review_heads FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable();
  SQL
  execute <<~SQL
    CREATE OR REPLACE FUNCTION public.savings_plan_context_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.financial_baseline_version_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM financial_baseline_versions v JOIN financial_baseline_heads h ON h.id = v.financial_baseline_head_id
        JOIN savings_enrollments e ON e.id = NEW.savings_enrollment_id
        WHERE v.id = NEW.financial_baseline_version_id AND v.household_id = e.household_id AND h.participant_user_id = e.user_id AND v.digest = NEW.baseline_digest
      ) THEN RAISE EXCEPTION 'plan baseline participant boundary'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~SQL
    CREATE TRIGGER savings_plan_drafts_context BEFORE INSERT OR UPDATE ON public.savings_plan_drafts FOR EACH ROW EXECUTE FUNCTION savings_plan_context_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER savings_plan_versions_context BEFORE INSERT ON public.savings_plan_versions FOR EACH ROW EXECUTE FUNCTION savings_plan_context_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_evidence_head_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE enrollment savings_enrollments; entry savings_entry_versions; version savings_evidence_versions; row RECORD; total numeric; expected_bindings jsonb; actual_bindings jsonb;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'evidence identity cannot be deleted'; END IF;
      IF TG_OP='UPDATE' AND ROW(NEW.household_id,NEW.savings_enrollment_id,NEW.savings_entry_version_id) IS DISTINCT FROM ROW(OLD.household_id,OLD.savings_enrollment_id,OLD.savings_entry_version_id) THEN RAISE EXCEPTION 'evidence identity is frozen'; END IF;
      SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=NEW.savings_enrollment_id;
      SELECT * INTO STRICT entry FROM savings_entry_versions WHERE id=NEW.savings_entry_version_id;
      IF enrollment.household_id <> NEW.household_id OR entry.savings_enrollment_id <> enrollment.id THEN RAISE EXCEPTION 'evidence household or entry scope invalid'; END IF;
      PERFORM 1 FROM households WHERE id=NEW.household_id FOR UPDATE;
      IF NEW.current_version_id IS NOT NULL THEN
        SELECT * INTO STRICT version FROM savings_evidence_versions WHERE id=NEW.current_version_id;
        IF version.savings_evidence_allocation_id <> NEW.id OR (TG_OP='UPDATE' AND NEW.current_version_id IS DISTINCT FROM OLD.current_version_id AND version.previous_version_id IS DISTINCT FROM OLD.current_version_id) THEN RAISE EXCEPTION 'evidence head must advance'; END IF;
        IF version.state='attached' THEN
          IF entry.signed_cents <= 0 OR entry.funding_source NOT IN ('earned_income','gift','bonus','new_money_reserved') OR version.supported_cents > entry.signed_cents OR entry.id IS DISTINCT FROM (SELECT current_approved_version_id FROM savings_entries WHERE id=entry.savings_entry_id) THEN RAISE EXCEPTION 'evidence must support current eligible contribution'; END IF;
          IF (SELECT SUM((proof->>'amount_cents')::bigint) FROM jsonb_array_elements(version.proof_snapshot) proof) <> version.supported_cents THEN RAISE EXCEPTION 'evidence proof total invalid'; END IF;
          SELECT jsonb_agg(binding ORDER BY (binding->>'event_id')::bigint) INTO expected_bindings FROM jsonb_array_elements(version.proof_snapshot) proof, jsonb_array_elements(proof->'bindings') binding;
          SELECT jsonb_agg(jsonb_build_object('event_id',financial_source_event_id,'source_review_version_id',source_review_version_id,'capacity_cents',capacity_cents,'reserved_cents',reserved_cents) ORDER BY financial_source_event_id)
            INTO actual_bindings FROM savings_evidence_capacities WHERE savings_evidence_version_id=version.id;
          IF actual_bindings IS DISTINCT FROM expected_bindings THEN RAISE EXCEPTION 'evidence capacity bindings do not match reviewed proof'; END IF;
          FOR row IN SELECT c.*, e.household_id AS event_household, h.financial_source_event_id AS reviewed_event, abs(v.signed_amount_cents) AS reviewed_capacity
            FROM savings_evidence_capacities c JOIN financial_source_events e ON e.id=c.financial_source_event_id
            JOIN source_review_versions v ON v.id=c.source_review_version_id JOIN source_review_heads h ON h.id=v.source_review_head_id WHERE c.savings_evidence_version_id=version.id LOOP
            IF row.event_household <> NEW.household_id OR row.reviewed_event <> row.financial_source_event_id OR row.capacity_cents > row.reviewed_capacity THEN RAISE EXCEPTION 'canonical evidence capacity scope invalid'; END IF;
            SELECT COALESCE(SUM(c.reserved_cents),0) INTO total FROM savings_evidence_capacities c JOIN savings_evidence_allocations a ON a.current_version_id=c.savings_evidence_version_id
              WHERE a.id <> NEW.id AND c.financial_source_event_id=row.financial_source_event_id;
            IF total + row.reserved_cents > row.capacity_cents THEN RAISE EXCEPTION 'canonical movement evidence capacity exceeded'; END IF;
          END LOOP;
          IF NOT EXISTS (SELECT 1 FROM savings_evidence_capacities WHERE savings_evidence_version_id=version.id) THEN RAISE EXCEPTION 'evidence requires canonical capacity bindings'; END IF;
        END IF;
      ELSIF TG_OP='UPDATE' AND OLD.current_version_id IS NOT NULL THEN RAISE EXCEPTION 'evidence cannot hide its history'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_evidence_identity BEFORE INSERT OR DELETE OR UPDATE ON public.savings_evidence_allocations FOR EACH ROW EXECUTE FUNCTION savings_evidence_head_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_evidence_version_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE enrollment savings_enrollments; head savings_evidence_allocations; prior savings_evidence_versions;
    BEGIN
      IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'approved savings evidence is immutable'; END IF;
      SELECT * INTO STRICT head FROM savings_evidence_allocations WHERE id=NEW.savings_evidence_allocation_id;
      SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=head.savings_enrollment_id;
      PERFORM 1 FROM households WHERE id=head.household_id FOR UPDATE;
      IF NEW.savings_enrollment_id <> enrollment.id OR NEW.approved_by_user_id <> enrollment.user_id OR enrollment.status <> 'active'
        OR NEW.previous_version_id IS DISTINCT FROM head.current_version_id OR NEW.approval_sequence <> enrollment.approval_sequence THEN
        RAISE EXCEPTION 'savings evidence approval scope or sequence invalid';
      END IF;
      IF NEW.previous_version_id IS NOT NULL THEN
        SELECT * INTO STRICT prior FROM savings_evidence_versions WHERE id=NEW.previous_version_id;
        IF NEW.version_number <> prior.version_number+1 THEN RAISE EXCEPTION 'evidence revision must advance'; END IF;
      ELSIF NEW.version_number <> 1 THEN RAISE EXCEPTION 'invalid first evidence revision'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_evidence_version_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.savings_evidence_versions FOR EACH ROW EXECUTE FUNCTION savings_evidence_version_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_evidence_published_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF (SELECT current_version_id FROM savings_evidence_allocations WHERE id=NEW.savings_evidence_allocation_id) IS DISTINCT FROM
        (SELECT id FROM savings_evidence_versions WHERE savings_evidence_allocation_id=NEW.savings_evidence_allocation_id ORDER BY version_number DESC LIMIT 1)
        THEN RAISE EXCEPTION 'evidence revision must publish atomically'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE CONSTRAINT TRIGGER savings_evidence_published AFTER INSERT ON public.savings_evidence_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION savings_evidence_published_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_evidence_sequence_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF EXISTS (SELECT 1 FROM savings_evidence_versions WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence)
        OR (TG_TABLE_NAME='savings_evidence_versions' AND EXISTS (
          SELECT 1 FROM savings_entry_versions WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence
          UNION ALL SELECT 1 FROM savings_plan_versions WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence
          UNION ALL SELECT 1 FROM savings_zero_attestations WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence
        )) THEN RAISE EXCEPTION 'savings evidence sequence already allocated'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_entry_versions_evidence_sequence BEFORE INSERT ON public.savings_entry_versions FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_evidence_versions_evidence_sequence BEFORE INSERT ON public.savings_evidence_versions FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_plan_versions_evidence_sequence BEFORE INSERT ON public.savings_plan_versions FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_zero_attestations_evidence_sequence BEFORE INSERT ON public.savings_zero_attestations FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_evidence_capacity_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'evidence capacities are immutable'; END IF;
      IF EXISTS (SELECT 1 FROM savings_evidence_versions v JOIN savings_evidence_allocations a ON a.id=v.savings_evidence_allocation_id
        WHERE v.id=NEW.savings_evidence_version_id AND (a.current_version_id=v.id OR v.previous_version_id IS DISTINCT FROM a.current_version_id)) THEN RAISE EXCEPTION 'published capacity bindings are terminal'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_evidence_capacity_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.savings_evidence_capacities FOR EACH ROW EXECUTE FUNCTION savings_evidence_capacity_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_debt_scope_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE enrollment savings_enrollments; card savings_debt_cards; version savings_debt_versions; prior savings_debt_versions; identity source_account_identity_versions; source_account financial_source_accounts; approval source_revision_approvals;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'participant card identity and history cannot be deleted'; END IF;
      IF TG_TABLE_NAME='savings_debt_cards' THEN
        SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=NEW.savings_enrollment_id;
        PERFORM 1 FROM households WHERE id=enrollment.household_id FOR UPDATE;
        IF NEW.household_id <> enrollment.household_id OR NEW.user_id <> enrollment.user_id THEN RAISE EXCEPTION 'card participant scope invalid'; END IF;
        IF TG_OP='UPDATE' AND ROW(NEW.savings_enrollment_id,NEW.household_id,NEW.user_id) IS DISTINCT FROM ROW(OLD.savings_enrollment_id,OLD.household_id,OLD.user_id) THEN RAISE EXCEPTION 'card identity is frozen'; END IF;
        IF NEW.current_version_id IS NOT NULL THEN
          SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.current_version_id;
          IF version.savings_debt_card_id <> NEW.id OR NEW.source_tracked_account_id IS DISTINCT FROM version.source_tracked_account_id OR (TG_OP='UPDATE' AND NEW.current_version_id IS DISTINCT FROM OLD.current_version_id AND version.previous_version_id IS DISTINCT FROM OLD.current_version_id) THEN RAISE EXCEPTION 'card approved head must advance'; END IF;
        ELSIF NEW.source_tracked_account_id IS NOT NULL OR (TG_OP='UPDATE' AND OLD.current_version_id IS NOT NULL) THEN RAISE EXCEPTION 'approved card head cannot be cleared'; END IF;
        RETURN NEW;
      END IF;
      SELECT * INTO STRICT card FROM savings_debt_cards WHERE id=NEW.savings_debt_card_id;
      SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=card.savings_enrollment_id;
      PERFORM 1 FROM households WHERE id=enrollment.household_id FOR UPDATE;
      IF NEW.savings_enrollment_id <> enrollment.id THEN RAISE EXCEPTION 'card review enrollment invalid'; END IF;
      IF TG_OP='UPDATE' THEN
        IF TG_TABLE_NAME='savings_debt_versions' THEN RAISE EXCEPTION 'approved card terms are immutable'; END IF;
        IF (to_jsonb(NEW)-ARRAY['status','approved_version_id','lock_version','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','approved_version_id','lock_version','updated_at']) OR OLD.status<>'pending' OR NEW.status<>'approved' THEN RAISE EXCEPTION 'reviewed card draft is frozen'; END IF;
        SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.approved_version_id;
        IF version.id IS DISTINCT FROM card.current_version_id OR version.savings_debt_card_id<>card.id OR version.terms IS DISTINCT FROM NEW.terms OR version.previous_version_id IS DISTINCT FROM NEW.base_version_id OR ROW(version.source_tracked_account_id,version.source_account_identity_version_id,version.source_revision_approval_id,version.source_fingerprint,version.source_snapshot) IS DISTINCT FROM ROW(NEW.source_tracked_account_id,NEW.source_account_identity_version_id,NEW.source_revision_approval_id,NEW.source_fingerprint,NEW.source_snapshot) THEN RAISE EXCEPTION 'card approval does not match reviewed draft'; END IF;
        RETURN NEW;
      END IF;
      IF enrollment.status<>'active' OR NOT EXISTS (SELECT 1 FROM users WHERE id=enrollment.user_id AND role='participant' AND invitation_status<>'revoked') THEN RAISE EXCEPTION 'card review participant unavailable'; END IF;
      IF TG_TABLE_NAME='savings_debt_versions' THEN
        IF NEW.approved_by_user_id<>enrollment.user_id OR NEW.previous_version_id IS DISTINCT FROM card.current_version_id THEN RAISE EXCEPTION 'card approval actor or prior head invalid'; END IF;
        IF NEW.previous_version_id IS NULL THEN
          IF NEW.version_number<>1 THEN RAISE EXCEPTION 'card first version invalid'; END IF;
        ELSE
          SELECT * INTO STRICT prior FROM savings_debt_versions WHERE id=NEW.previous_version_id;
          IF NEW.version_number<>prior.version_number+1 OR btrim(NEW.reason)='' OR (NEW.terms->>'as_of_on')::date < (prior.terms->>'as_of_on')::date THEN RAISE EXCEPTION 'card revision must advance without older statement overwrite'; END IF;
        END IF;
      ELSE
        IF NEW.created_by_user_id<>enrollment.user_id OR NEW.base_version_id IS DISTINCT FROM card.current_version_id OR NEW.base_head_lock_version<>card.lock_version OR NEW.status<>'pending' THEN RAISE EXCEPTION 'card draft actor or head invalid'; END IF;
      END IF;
      IF NEW.source_tracked_account_id IS NOT NULL THEN
        SELECT * INTO STRICT identity FROM source_account_identity_versions WHERE id=NEW.source_account_identity_version_id;
        SELECT a.* INTO STRICT source_account FROM source_account_review_heads h JOIN financial_source_accounts a ON a.id=h.financial_source_account_id WHERE h.id=identity.source_account_review_head_id AND h.approved_version_id=identity.id;
        SELECT * INTO STRICT approval FROM source_revision_approvals WHERE id=NEW.source_revision_approval_id;
        IF identity.household_id<>enrollment.household_id OR identity.source_tracked_account_id<>NEW.source_tracked_account_id OR approval.household_id<>enrollment.household_id OR approval.financial_extraction_revision_id<>source_account.financial_extraction_revision_id OR NOT EXISTS (SELECT 1 FROM source_tracked_accounts WHERE id=NEW.source_tracked_account_id AND household_id=enrollment.household_id AND account_basis='liability') OR NEW.terms->>'as_of_on' IS DISTINCT FROM identity.statement_facts->>'period_end_on' OR NEW.source_snapshot->>'identity_digest' IS DISTINCT FROM identity.digest OR NEW.source_snapshot->>'revision_digest' IS DISTINCT FROM approval.digest OR NEW.source_snapshot->'statement_closing_balance_cents' IS DISTINCT FROM identity.statement_facts->'closing_balance_cents' THEN RAISE EXCEPTION 'card source mapping scope or reviewed facts invalid'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_debt_cards_guard BEFORE INSERT OR DELETE OR UPDATE ON public.savings_debt_cards FOR EACH ROW EXECUTE FUNCTION savings_debt_scope_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_debt_drafts_guard BEFORE INSERT OR DELETE OR UPDATE ON public.savings_debt_drafts FOR EACH ROW EXECUTE FUNCTION savings_debt_scope_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_debt_versions_guard BEFORE INSERT OR DELETE OR UPDATE ON public.savings_debt_versions FOR EACH ROW EXECUTE FUNCTION savings_debt_scope_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_debt_household_link_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE card savings_debt_cards; version savings_debt_versions; debt debts;
    BEGIN
      IF TG_TABLE_NAME='savings_debt_cards' THEN
        card := NEW;
        IF NEW.current_version_id IS NOT NULL THEN
          SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.current_version_id;
          IF NEW.household_debt_id IS DISTINCT FROM version.household_debt_id THEN RAISE EXCEPTION 'card household link must match approved version'; END IF;
        ELSIF NEW.household_debt_id IS NOT NULL THEN RAISE EXCEPTION 'card household link requires approved terms'; END IF;
      ELSE
        SELECT * INTO STRICT card FROM savings_debt_cards WHERE id=NEW.savings_debt_card_id;
        IF TG_TABLE_NAME='savings_debt_drafts' AND TG_OP='UPDATE' THEN
          SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.approved_version_id;
          IF ROW(NEW.household_debt_id,NEW.household_debt_fingerprint,NEW.household_debt_snapshot) IS DISTINCT FROM ROW(version.household_debt_id,version.household_debt_fingerprint,version.household_debt_snapshot) THEN RAISE EXCEPTION 'approved household link does not match draft'; END IF;
        END IF;
      END IF;
      IF NEW.household_debt_id IS NOT NULL THEN
        SELECT * INTO STRICT debt FROM debts WHERE id=NEW.household_debt_id;
        IF debt.household_id<>card.household_id OR debt.debt_type<>'credit_card' THEN RAISE EXCEPTION 'household card link scope invalid'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_debt_cards_household_link_guard BEFORE INSERT OR UPDATE ON public.savings_debt_cards FOR EACH ROW EXECUTE FUNCTION savings_debt_household_link_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_debt_drafts_household_link_guard BEFORE INSERT OR UPDATE ON public.savings_debt_drafts FOR EACH ROW EXECUTE FUNCTION savings_debt_household_link_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_debt_versions_household_link_guard BEFORE INSERT OR UPDATE ON public.savings_debt_versions FOR EACH ROW EXECUTE FUNCTION savings_debt_household_link_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.debts_optional_card_identity_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
        BEGIN
          IF NEW.household_id IS DISTINCT FROM OLD.household_id THEN
            PERFORM 1 FROM households WHERE id=OLD.household_id FOR UPDATE;
            IF (
              EXISTS (SELECT 1 FROM savings_debt_cards WHERE household_debt_id=OLD.id) OR
              EXISTS (SELECT 1 FROM savings_debt_drafts WHERE household_debt_id=OLD.id) OR
              EXISTS (SELECT 1 FROM savings_debt_versions WHERE household_debt_id=OLD.id)
            ) THEN RAISE EXCEPTION 'optional card review history household identity cannot change'; END IF;
          END IF;
          RETURN NEW;
        END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER debts_optional_card_identity_guard BEFORE UPDATE OF household_id ON public.debts FOR EACH ROW EXECUTE FUNCTION debts_optional_card_identity_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_daily_version_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE e savings_enrollments; h RECORD; prior RECORD; data jsonb;
    BEGIN
      IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'daily approved history is immutable'; END IF;
      SELECT * INTO STRICT e FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
      IF NEW.approved_by_user_id <> e.user_id OR e.status NOT IN ('active','completed') THEN RAISE EXCEPTION 'daily participant boundary'; END IF;
      data := to_jsonb(NEW);
      EXECUTE format('SELECT * FROM %I WHERE id = $1', TG_ARGV[0]) INTO STRICT h USING (data->>TG_ARGV[1])::bigint;
      IF NEW.previous_version_id IS DISTINCT FROM h.current_version_id THEN RAISE EXCEPTION 'daily stale predecessor'; END IF;
      IF NEW.previous_version_id IS NULL THEN
        IF NEW.version_number <> 1 THEN RAISE EXCEPTION 'daily first version'; END IF;
      ELSE
        EXECUTE format('SELECT * FROM %I WHERE id = $1', TG_TABLE_NAME) INTO STRICT prior USING NEW.previous_version_id;
        IF NEW.version_number <> prior.version_number + 1 OR char_length(trim(NEW.reason)) = 0 THEN RAISE EXCEPTION 'daily correction needs reason'; END IF;
      END IF;
      IF data ? 'daily_sequence' AND NOT EXISTS (SELECT 1 FROM savings_daily_ledgers l WHERE l.savings_enrollment_id = e.id AND l.sequence = (data->>'daily_sequence')::integer) THEN RAISE EXCEPTION 'daily sequence boundary'; END IF;
      IF TG_TABLE_NAME = 'savings_daily_purchase_versions' THEN
        IF (data->>'purchased_on')::date NOT BETWEEN e.starts_on AND LEAST(e.ends_on,(NEW.approved_at AT TIME ZONE 'UTC' AT TIME ZONE e.time_zone)::date) OR NOT EXISTS (SELECT 1 FROM household_transactions tx WHERE tx.id = (data->>'household_transaction_id')::bigint AND tx.household_id = e.household_id) THEN RAISE EXCEPTION 'daily purchase scope'; END IF;
        IF data->>'disposition' = 'void' THEN
          IF NEW.previous_version_id IS NULL OR to_jsonb(prior)->>'disposition' <> 'purchase' OR to_jsonb(prior)->>'link_kind' <> 'manual_new' OR
            data->>'household_transaction_id' IS DISTINCT FROM to_jsonb(prior)->>'household_transaction_id' OR
            NOT EXISTS (SELECT 1 FROM household_transactions tx WHERE tx.id = (data->>'household_transaction_id')::bigint AND tx.financial_source_event_id IS NULL AND tx.status = 'ignored' AND (tx.metadata->>'savings_daily_purchase_id')::bigint = h.id) THEN RAISE EXCEPTION 'daily void ownership'; END IF;
        ELSE
          IF NOT EXISTS (SELECT 1 FROM household_transactions tx WHERE tx.id = (data->>'household_transaction_id')::bigint AND tx.total_amount_cents = (data->>'amount_cents')::bigint AND tx.merchant = data->>'merchant' AND tx.status IN ('confirmed','reconciled')) THEN RAISE EXCEPTION 'daily canonical facts'; END IF;
        END IF;
      ELSIF TG_TABLE_NAME = 'savings_daily_check_in_versions' THEN
        IF (to_jsonb(h)->>'local_on')::date NOT BETWEEN e.starts_on AND LEAST(e.ends_on,(NEW.approved_at AT TIME ZONE 'UTC' AT TIME ZONE e.time_zone)::date) THEN RAISE EXCEPTION 'daily check-in calendar'; END IF;
        IF data->>'spending_state' = 'no_spend' AND EXISTS (SELECT 1 FROM savings_daily_purchase_versions v JOIN savings_daily_purchases p ON p.current_version_id = v.id WHERE v.savings_enrollment_id = e.id AND v.purchased_on = (to_jsonb(h)->>'local_on')::date AND v.disposition = 'purchase') THEN RAISE EXCEPTION 'daily no-spend conflicts with approved purchase'; END IF;
      ELSIF TG_TABLE_NAME = 'savings_checkpoint_versions' THEN
        IF data->'snapshot'->>'calculation_version' <> 'savings_checkpoint_v1' OR
          (data->'snapshot'->>'milestone_day')::integer IS DISTINCT FROM (to_jsonb(h)->>'milestone_day')::integer OR
          (data->'snapshot'->>'cutoff_on')::date IS DISTINCT FROM e.starts_on + (to_jsonb(h)->>'milestone_day')::integer - 1 OR
          (data->'snapshot'->>'cutoff_on')::date > (NEW.approved_at AT TIME ZONE 'UTC' AT TIME ZONE e.time_zone)::date OR
          data->'snapshot'->>'time_zone' IS DISTINCT FROM e.time_zone OR
          (data->'snapshot'->>'accepted_cohort_release_id')::bigint IS DISTINCT FROM e.accepted_cohort_release_id OR
          (data->'snapshot'->>'financial_approval_sequence')::integer IS DISTINCT FROM e.approval_sequence OR
          (data->'snapshot'->>'daily_approval_sequence')::integer IS DISTINCT FROM COALESCE((SELECT sequence FROM savings_daily_ledgers WHERE savings_enrollment_id=e.id),0) THEN RAISE EXCEPTION 'checkpoint frozen boundary'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_checkpoint_versions_immutable BEFORE DELETE OR UPDATE ON public.savings_checkpoint_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('savings_checkpoints', 'savings_checkpoint_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_checkpoint_versions_insert BEFORE INSERT ON public.savings_checkpoint_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('savings_checkpoints', 'savings_checkpoint_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_check_in_versions_immutable BEFORE DELETE OR UPDATE ON public.savings_daily_check_in_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('savings_daily_check_ins', 'savings_daily_check_in_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_check_in_versions_insert BEFORE INSERT ON public.savings_daily_check_in_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('savings_daily_check_ins', 'savings_daily_check_in_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_purchase_versions_immutable BEFORE DELETE OR UPDATE ON public.savings_daily_purchase_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('savings_daily_purchases', 'savings_daily_purchase_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_purchase_versions_insert BEFORE INSERT ON public.savings_daily_purchase_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('savings_daily_purchases', 'savings_daily_purchase_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_reflection_versions_insert BEFORE INSERT ON public.savings_daily_reflection_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('savings_daily_reflections', 'savings_daily_reflection_id');
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_daily_head_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE version RECORD; data jsonb;
    BEGIN
      IF NEW.savings_enrollment_id IS DISTINCT FROM OLD.savings_enrollment_id THEN RAISE EXCEPTION 'daily identity is frozen'; END IF;
      IF NEW.current_version_id IS DISTINCT FROM OLD.current_version_id THEN
        EXECUTE format('SELECT * FROM %I WHERE id = $1', TG_ARGV[0]) INTO STRICT version USING NEW.current_version_id;
        data := to_jsonb(version);
        IF (data->>TG_ARGV[1])::bigint <> NEW.id OR version.previous_version_id IS DISTINCT FROM OLD.current_version_id THEN RAISE EXCEPTION 'daily head must advance'; END IF;
      END IF;
      IF TG_TABLE_NAME = 'savings_daily_check_ins' AND (to_jsonb(NEW)->'local_on') IS DISTINCT FROM (to_jsonb(OLD)->'local_on') THEN RAISE EXCEPTION 'daily date is frozen'; END IF;
      IF TG_TABLE_NAME = 'savings_checkpoints' AND (to_jsonb(NEW)->'milestone_day') IS DISTINCT FROM (to_jsonb(OLD)->'milestone_day') THEN RAISE EXCEPTION 'checkpoint milestone is frozen'; END IF;
      IF TG_TABLE_NAME = 'savings_daily_reflections' AND (to_jsonb(NEW)->'savings_daily_purchase_id') IS DISTINCT FROM (to_jsonb(OLD)->'savings_daily_purchase_id') THEN RAISE EXCEPTION 'reflection purchase is frozen'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_checkpoints_head BEFORE UPDATE ON public.savings_checkpoints FOR EACH ROW EXECUTE FUNCTION savings_daily_head_guard('savings_checkpoint_versions', 'savings_checkpoint_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_check_ins_head BEFORE UPDATE ON public.savings_daily_check_ins FOR EACH ROW EXECUTE FUNCTION savings_daily_head_guard('savings_daily_check_in_versions', 'savings_daily_check_in_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_purchases_head BEFORE UPDATE ON public.savings_daily_purchases FOR EACH ROW EXECUTE FUNCTION savings_daily_head_guard('savings_daily_purchase_versions', 'savings_daily_purchase_id');
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_reflections_head BEFORE UPDATE ON public.savings_daily_reflections FOR EACH ROW EXECUTE FUNCTION savings_daily_head_guard('savings_daily_reflection_versions', 'savings_daily_reflection_id');
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_daily_reflection_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE e savings_enrollments;
    BEGIN
      IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'reflection audit identity is retained'; END IF;
      SELECT * INTO STRICT e FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
      IF OLD.erased_at IS NOT NULL AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN RAISE EXCEPTION 'reflection tombstone is immutable'; END IF;
      IF (to_jsonb(NEW) - ARRAY['feeling_then','feeling_now','reason','erased_at','erased_by_user_id','updated_at']) IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['feeling_then','feeling_now','reason','erased_at','erased_by_user_id','updated_at']) OR NEW.feeling_then IS NOT NULL OR NEW.feeling_now IS NOT NULL OR NEW.reason <> '' OR NEW.erased_at IS NULL OR NEW.erased_by_user_id <> e.user_id THEN RAISE EXCEPTION 'reflection permits only private-text erasure'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_reflection_versions_immutable BEFORE DELETE OR UPDATE ON public.savings_daily_reflection_versions FOR EACH ROW EXECUTE FUNCTION savings_daily_reflection_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_daily_draft_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF OLD.status <> 'pending' THEN RAISE EXCEPTION 'approved daily draft is immutable'; END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      IF NEW.savings_enrollment_id IS DISTINCT FROM OLD.savings_enrollment_id OR NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id THEN RAISE EXCEPTION 'daily draft identity is frozen'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_checkpoint_drafts_terminal BEFORE DELETE OR UPDATE ON public.savings_checkpoint_drafts FOR EACH ROW EXECUTE FUNCTION savings_daily_draft_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER savings_daily_purchase_drafts_terminal BEFORE DELETE OR UPDATE ON public.savings_daily_purchase_drafts FOR EACH ROW EXECUTE FUNCTION savings_daily_draft_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_prevent_mutation()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN RAISE EXCEPTION 'approved savings history is immutable' USING ERRCODE = 'integrity_constraint_violation'; END; $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_scope_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE enrollment savings_enrollments; prior RECORD;
    BEGIN
      SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
      IF NEW.approved_by_user_id <> enrollment.user_id OR enrollment.status <> 'active' THEN
        RAISE EXCEPTION 'savings approval participant boundary' USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF NEW.approval_sequence <> enrollment.approval_sequence OR EXISTS (
        SELECT 1 FROM savings_entry_versions WHERE savings_enrollment_id = enrollment.id AND approval_sequence = NEW.approval_sequence
        UNION ALL SELECT 1 FROM savings_plan_versions WHERE savings_enrollment_id = enrollment.id AND approval_sequence = NEW.approval_sequence
        UNION ALL SELECT 1 FROM savings_zero_attestations WHERE savings_enrollment_id = enrollment.id AND approval_sequence = NEW.approval_sequence
      ) THEN RAISE EXCEPTION 'savings approval sequence must advance exclusively'; END IF;
      IF TG_TABLE_NAME = 'savings_entry_versions' THEN
        IF NEW.previous_version_id IS DISTINCT FROM (SELECT current_approved_version_id FROM savings_entries WHERE id = NEW.savings_entry_id) THEN
          RAISE EXCEPTION 'savings approval must replace the current approved head';
        END IF;
        IF NEW.effective_on NOT BETWEEN enrollment.starts_on AND enrollment.ends_on THEN
          RAISE EXCEPTION 'savings effective date outside challenge' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.previous_version_id IS NOT NULL THEN
          SELECT * INTO STRICT prior FROM savings_entry_versions WHERE id = NEW.previous_version_id;
          IF NEW.version_number <> prior.version_number + 1 THEN RAISE EXCEPTION 'savings version sequence invalid'; END IF;
        ELSIF NEW.version_number <> 1 THEN RAISE EXCEPTION 'savings initial version invalid'; END IF;
      ELSIF TG_TABLE_NAME = 'savings_plan_versions' THEN
        IF NEW.previous_version_id IS DISTINCT FROM enrollment.current_accepted_plan_version_id THEN RAISE EXCEPTION 'savings plan must replace current head'; END IF;
        IF NEW.previous_version_id IS NOT NULL THEN
          SELECT * INTO STRICT prior FROM savings_plan_versions WHERE id = NEW.previous_version_id;
          IF NEW.version_number <> prior.version_number + 1 THEN RAISE EXCEPTION 'savings plan sequence invalid'; END IF;
        ELSIF NEW.version_number <> 1 THEN RAISE EXCEPTION 'savings initial plan invalid'; END IF;
      ELSE
        IF NEW.cutoff_on NOT BETWEEN enrollment.starts_on AND enrollment.ends_on OR EXISTS (
          SELECT 1 FROM savings_entries e JOIN savings_entry_versions v ON v.id = e.current_approved_version_id
          WHERE e.savings_enrollment_id = enrollment.id AND v.effective_on <= NEW.cutoff_on
            AND v.funding_source IN ('earned_income','gift','bonus','new_money_reserved','withdrawal')
        ) THEN RAISE EXCEPTION 'savings zero attestation conflicts with ledger' USING ERRCODE = 'integrity_constraint_violation'; END IF;
        IF NEW.previous_attestation_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM savings_zero_attestations z WHERE z.id = NEW.previous_attestation_id AND z.savings_enrollment_id = enrollment.id AND z.cutoff_on = NEW.cutoff_on
        ) THEN RAISE EXCEPTION 'savings zero attestation scope invalid'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_identity_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'savings identity cannot be deleted'; END IF;
      IF TG_TABLE_NAME = 'savings_enrollments' THEN
        IF ROW(NEW.user_id,NEW.household_id,NEW.cohort_id,NEW.accepted_cohort_membership_id,NEW.membership_started_at,NEW.accepted_at,NEW.accepted_local_on,NEW.starts_on,NEW.ends_on,NEW.time_zone,NEW.policy_version,NEW.late_start_accepted)
          IS DISTINCT FROM ROW(OLD.user_id,OLD.household_id,OLD.cohort_id,OLD.accepted_cohort_membership_id,OLD.membership_started_at,OLD.accepted_at,OLD.accepted_local_on,OLD.starts_on,OLD.ends_on,OLD.time_zone,OLD.policy_version,OLD.late_start_accepted) THEN RAISE EXCEPTION 'savings enrollment identity is frozen'; END IF;
        IF NEW.current_accepted_plan_version_id IS DISTINCT FROM OLD.current_accepted_plan_version_id AND NOT EXISTS (
          SELECT 1 FROM savings_plan_versions v WHERE v.id = NEW.current_accepted_plan_version_id AND v.previous_version_id IS NOT DISTINCT FROM OLD.current_accepted_plan_version_id
        ) THEN RAISE EXCEPTION 'savings plan head must advance'; END IF;
      ELSE
        IF NEW.savings_enrollment_id <> OLD.savings_enrollment_id THEN RAISE EXCEPTION 'savings entry identity is frozen'; END IF;
        IF NEW.current_approved_version_id IS DISTINCT FROM OLD.current_approved_version_id AND NOT EXISTS (
          SELECT 1 FROM savings_entry_versions v WHERE v.id = NEW.current_approved_version_id AND v.previous_version_id IS NOT DISTINCT FROM OLD.current_approved_version_id
        ) THEN RAISE EXCEPTION 'savings entry head must advance'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_draft_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN IF OLD.status = 'approved' THEN RAISE EXCEPTION 'approved savings draft is terminal'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END; $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_approval_head_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE head_number integer; latest_number integer;
    BEGIN
      IF TG_TABLE_NAME = 'savings_entry_versions' THEN
        SELECT v.version_number INTO head_number FROM savings_entries e JOIN savings_entry_versions v ON v.id = e.current_approved_version_id WHERE e.id = NEW.savings_entry_id;
        SELECT MAX(version_number) INTO latest_number FROM savings_entry_versions WHERE savings_entry_id = NEW.savings_entry_id;
      ELSE
        SELECT v.version_number INTO head_number FROM savings_enrollments e JOIN savings_plan_versions v ON v.id = e.current_accepted_plan_version_id WHERE e.id = NEW.savings_enrollment_id;
        SELECT MAX(version_number) INTO latest_number FROM savings_plan_versions WHERE savings_enrollment_id = NEW.savings_enrollment_id;
      END IF;
      IF head_number IS DISTINCT FROM latest_number THEN RAISE EXCEPTION 'approved savings version must publish its current head atomically'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.savings_enrollment_release_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_OP = 'UPDATE' AND NEW.accepted_cohort_release_id IS DISTINCT FROM OLD.accepted_cohort_release_id THEN
        RAISE EXCEPTION 'accepted savings release is frozen';
      END IF;
      IF TG_OP = 'INSERT' AND (NEW.accepted_cohort_release_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM cohort_releases r WHERE r.id = NEW.accepted_cohort_release_id AND r.cohort_id = NEW.cohort_id
          AND r.tool_registry_version >= 3
          AND r.experience_snapshot->'config'->>'experience_mode' = 'savings_challenge'
      )) THEN RAISE EXCEPTION 'accepted savings release must match the challenge cohort'; END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_enrollments_identity ON savings_enrollments;
    CREATE TRIGGER savings_enrollments_identity BEFORE DELETE OR UPDATE ON public.savings_enrollments FOR EACH ROW EXECUTE FUNCTION savings_identity_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_enrollments_release ON savings_enrollments;
    CREATE TRIGGER savings_enrollments_release BEFORE INSERT OR UPDATE ON public.savings_enrollments FOR EACH ROW EXECUTE FUNCTION savings_enrollment_release_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_entries_identity ON savings_entries;
    CREATE TRIGGER savings_entries_identity BEFORE DELETE OR UPDATE ON public.savings_entries FOR EACH ROW EXECUTE FUNCTION savings_identity_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_entry_drafts_terminal ON savings_entry_drafts;
    CREATE TRIGGER savings_entry_drafts_terminal BEFORE DELETE OR UPDATE ON public.savings_entry_drafts FOR EACH ROW EXECUTE FUNCTION savings_draft_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_entry_versions_evidence_sequence ON savings_entry_versions;
    CREATE TRIGGER savings_entry_versions_evidence_sequence BEFORE INSERT ON public.savings_entry_versions FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_entry_versions_immutable ON savings_entry_versions;
    CREATE TRIGGER savings_entry_versions_immutable BEFORE DELETE OR UPDATE ON public.savings_entry_versions FOR EACH ROW EXECUTE FUNCTION savings_prevent_mutation();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_entry_versions_published ON savings_entry_versions;
    CREATE CONSTRAINT TRIGGER savings_entry_versions_published AFTER INSERT ON public.savings_entry_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION savings_approval_head_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_entry_versions_scope ON savings_entry_versions;
    CREATE TRIGGER savings_entry_versions_scope BEFORE INSERT ON public.savings_entry_versions FOR EACH ROW EXECUTE FUNCTION savings_scope_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_plan_drafts_context ON savings_plan_drafts;
    CREATE TRIGGER savings_plan_drafts_context BEFORE INSERT OR UPDATE ON public.savings_plan_drafts FOR EACH ROW EXECUTE FUNCTION savings_plan_context_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_plan_drafts_terminal ON savings_plan_drafts;
    CREATE TRIGGER savings_plan_drafts_terminal BEFORE DELETE OR UPDATE ON public.savings_plan_drafts FOR EACH ROW EXECUTE FUNCTION savings_draft_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_plan_versions_context ON savings_plan_versions;
    CREATE TRIGGER savings_plan_versions_context BEFORE INSERT ON public.savings_plan_versions FOR EACH ROW EXECUTE FUNCTION savings_plan_context_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_plan_versions_evidence_sequence ON savings_plan_versions;
    CREATE TRIGGER savings_plan_versions_evidence_sequence BEFORE INSERT ON public.savings_plan_versions FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_plan_versions_immutable ON savings_plan_versions;
    CREATE TRIGGER savings_plan_versions_immutable BEFORE DELETE OR UPDATE ON public.savings_plan_versions FOR EACH ROW EXECUTE FUNCTION savings_prevent_mutation();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_plan_versions_published ON savings_plan_versions;
    CREATE CONSTRAINT TRIGGER savings_plan_versions_published AFTER INSERT ON public.savings_plan_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION savings_approval_head_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_plan_versions_scope ON savings_plan_versions;
    CREATE TRIGGER savings_plan_versions_scope BEFORE INSERT ON public.savings_plan_versions FOR EACH ROW EXECUTE FUNCTION savings_scope_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_zero_attestations_evidence_sequence ON savings_zero_attestations;
    CREATE TRIGGER savings_zero_attestations_evidence_sequence BEFORE INSERT ON public.savings_zero_attestations FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_zero_attestations_immutable ON savings_zero_attestations;
    CREATE TRIGGER savings_zero_attestations_immutable BEFORE DELETE OR UPDATE ON public.savings_zero_attestations FOR EACH ROW EXECUTE FUNCTION savings_prevent_mutation();
  SQL
  execute <<~'SQL'
    DROP TRIGGER IF EXISTS savings_zero_attestations_scope ON savings_zero_attestations;
    CREATE TRIGGER savings_zero_attestations_scope BEFORE INSERT ON public.savings_zero_attestations FOR EACH ROW EXECUTE FUNCTION savings_scope_guard();
  SQL
  execute <<~SQL
    CREATE OR REPLACE FUNCTION public.source_accounting_facts_immutable()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_TABLE_NAME = 'financial_extraction_revisions' THEN
        IF (to_jsonb(NEW) - 'financial_document_import_id' - 'financial_document_import_attempt_id') <> (to_jsonb(OLD) - 'financial_document_import_id' - 'financial_document_import_attempt_id') OR
           (NEW.financial_document_import_id IS DISTINCT FROM OLD.financial_document_import_id AND NEW.financial_document_import_id IS NOT NULL) OR
           (NEW.financial_document_import_attempt_id IS DISTINCT FROM OLD.financial_document_import_attempt_id AND NEW.financial_document_import_attempt_id IS NOT NULL) THEN
          RAISE EXCEPTION 'Source accounting facts are immutable; append a revision';
        END IF;
      ELSIF to_jsonb(NEW) <> to_jsonb(OLD) THEN
        RAISE EXCEPTION 'Source accounting facts are immutable; append a revision';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~SQL
    DROP TRIGGER IF EXISTS financial_extraction_revisions_immutable ON financial_extraction_revisions;
    CREATE TRIGGER financial_extraction_revisions_immutable BEFORE UPDATE ON public.financial_extraction_revisions FOR EACH ROW EXECUTE FUNCTION source_accounting_facts_immutable();
  SQL
  execute <<~SQL
    DROP TRIGGER IF EXISTS financial_source_accounts_immutable ON financial_source_accounts;
    CREATE TRIGGER financial_source_accounts_immutable BEFORE UPDATE ON public.financial_source_accounts FOR EACH ROW EXECUTE FUNCTION source_accounting_facts_immutable();
  SQL
  execute <<~SQL
    DROP TRIGGER IF EXISTS financial_source_events_immutable ON financial_source_events;
    CREATE TRIGGER financial_source_events_immutable BEFORE UPDATE ON public.financial_source_events FOR EACH ROW EXECUTE FUNCTION source_accounting_facts_immutable();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.financial_picture_write_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE current_generation integer;
    BEGIN
      SELECT financial_generation INTO current_generation FROM households WHERE id = NEW.household_id FOR UPDATE;
      IF NEW.financial_generation IS DISTINCT FROM current_generation THEN
        IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'accounts' THEN
          IF NEW.plaid_account_id IS NULL AND (to_jsonb(NEW) - ARRAY['plaid_account_id', 'updated_at']) = (to_jsonb(OLD) - ARRAY['plaid_account_id', 'updated_at']) THEN
            RETURN NEW;
          END IF;
        END IF;
        IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'transaction_drafts' THEN
          IF (to_jsonb(NEW) - ARRAY['raw_input', 'draft_payload', 'merchant', 'updated_at']) = (to_jsonb(OLD) - ARRAY['raw_input', 'draft_payload', 'merchant', 'updated_at'])
            AND NEW.raw_input IS NULL AND NEW.draft_payload = '{}'::jsonb
            AND (NEW.merchant = OLD.merchant OR (NEW.merchant = 'Source row' AND OLD.status IN ('pending', 'ignored'))) THEN
            RETURN NEW;
          END IF;
        END IF;
        IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'mia_action_drafts' THEN
          IF (to_jsonb(NEW) - ARRAY['source_chat_message_id', 'assistant_chat_message_id', 'metadata', 'updated_at']) = (to_jsonb(OLD) - ARRAY['source_chat_message_id', 'assistant_chat_message_id', 'metadata', 'updated_at'])
            AND (NEW.source_chat_message_id IS NULL OR NEW.source_chat_message_id = OLD.source_chat_message_id)
            AND (NEW.assistant_chat_message_id IS NULL OR NEW.assistant_chat_message_id = OLD.assistant_chat_message_id)
            AND (NEW.metadata - 'review_program_scope') = (OLD.metadata - 'review_program_scope') THEN
            RETURN NEW;
          END IF;
        END IF;
        RAISE EXCEPTION 'financial_generation_stale: reload the current financial picture' USING ERRCODE = '23514';
      END IF;
      IF TG_OP = 'UPDATE' AND TG_TABLE_NAME <> 'household_profiles' AND NEW.financial_generation IS DISTINCT FROM OLD.financial_generation THEN
        RAISE EXCEPTION 'financial picture generation cannot change' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER accounts_financial_picture_guard BEFORE INSERT OR UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER budget_categories_financial_picture_guard BEFORE INSERT OR UPDATE ON public.budget_categories FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER budget_years_financial_picture_guard BEFORE INSERT OR UPDATE ON public.budget_years FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER debts_financial_picture_guard BEFORE INSERT OR UPDATE ON public.debts FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER expense_items_financial_picture_guard BEFORE INSERT OR UPDATE ON public.expense_items FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER goals_financial_picture_guard BEFORE INSERT OR UPDATE ON public.goals FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER household_profiles_financial_picture_guard BEFORE INSERT OR UPDATE ON public.household_profiles FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER household_transactions_financial_picture_guard BEFORE INSERT OR UPDATE ON public.household_transactions FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER income_sources_financial_picture_guard BEFORE INSERT OR UPDATE ON public.income_sources FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER merchant_category_rules_financial_picture_guard BEFORE INSERT OR UPDATE ON public.merchant_category_rules FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER mia_action_drafts_financial_picture_guard BEFORE INSERT OR UPDATE ON public.mia_action_drafts FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER transaction_drafts_financial_picture_guard BEFORE INSERT OR UPDATE ON public.transaction_drafts FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.financial_chat_write_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE current_generation integer;
    BEGIN
      SELECT financial_generation INTO current_generation FROM households WHERE id = NEW.household_id FOR UPDATE;
      IF NEW.financial_generation IS DISTINCT FROM current_generation THEN
        RAISE EXCEPTION 'financial_generation_stale: chat continuity changed' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER chat_sessions_financial_picture_guard BEFORE INSERT OR UPDATE ON public.chat_sessions FOR EACH ROW EXECUTE FUNCTION financial_chat_write_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.bank_activity_generation_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.financial_generation IS DISTINCT FROM OLD.financial_generation OR NEW.plaid_item_id IS DISTINCT FROM OLD.plaid_item_id THEN
        RAISE EXCEPTION 'bank activity financial generation cannot change' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER plaid_transactions_financial_generation_guard BEFORE UPDATE ON public.plaid_transactions FOR EACH ROW EXECUTE FUNCTION bank_activity_generation_guard();
  SQL
  execute <<~SQL
CREATE OR REPLACE FUNCTION public.enforce_enterprise_mapping_boundary()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM enterprise_organizations o JOIN cohorts c ON c.coach_workspace_id = o.coach_workspace_id
    WHERE o.id = NEW.enterprise_organization_id AND c.id = NEW.cohort_id
  ) THEN RAISE EXCEPTION 'Enterprise group mapping must remain in its program' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END;
$function$
;
DROP TRIGGER IF EXISTS enterprise_mapping_boundary ON enterprise_group_mappings;
CREATE TRIGGER enterprise_mapping_boundary BEFORE INSERT OR UPDATE ON public.enterprise_group_mappings FOR EACH ROW EXECUTE FUNCTION enforce_enterprise_mapping_boundary();
  SQL
  execute <<~SQL
CREATE OR REPLACE FUNCTION public.enforce_enterprise_directory_boundary()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.enterprise_membership_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM enterprise_memberships m WHERE m.id = NEW.enterprise_membership_id AND m.enterprise_organization_id = NEW.enterprise_organization_id
  ) THEN RAISE EXCEPTION 'Enterprise directory membership must remain in its organization' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END;
$function$
;
DROP TRIGGER IF EXISTS enterprise_directory_boundary ON enterprise_directory_users;
CREATE TRIGGER enterprise_directory_boundary BEFORE INSERT OR UPDATE ON public.enterprise_directory_users FOR EACH ROW EXECUTE FUNCTION enforce_enterprise_directory_boundary();
  SQL
  execute <<~SQL
CREATE OR REPLACE FUNCTION public.enforce_enterprise_grant_boundary()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM enterprise_memberships m
    JOIN enterprise_organizations o ON o.id = m.enterprise_organization_id
    JOIN cohort_memberships cm ON cm.id = NEW.cohort_membership_id AND cm.user_id = m.user_id AND cm.role = 'participant'
    JOIN cohorts c ON c.id = cm.cohort_id AND c.coach_workspace_id = o.coach_workspace_id
    WHERE m.id = NEW.enterprise_membership_id
  ) THEN RAISE EXCEPTION 'Enterprise grants may only enroll their participant in their program' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END;
$function$
;
DROP TRIGGER IF EXISTS enterprise_grant_boundary ON enterprise_cohort_grants;
CREATE TRIGGER enterprise_grant_boundary BEFORE INSERT OR UPDATE ON public.enterprise_cohort_grants FOR EACH ROW EXECUTE FUNCTION enforce_enterprise_grant_boundary();
  SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION prevent_cohort_release_mutation()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    RAISE EXCEPTION 'cohort releases are immutable'
      USING ERRCODE = 'integrity_constraint_violation';
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_releases_immutable ON cohort_releases;
  CREATE TRIGGER cohort_releases_immutable
  BEFORE UPDATE OR DELETE ON cohort_releases
  FOR EACH ROW
  EXECUTE FUNCTION prevent_cohort_release_mutation()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION prevent_coach_operation_execution_mutation()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    RAISE EXCEPTION 'coach operation executions are immutable'
      USING ERRCODE = 'integrity_constraint_violation';
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS coach_operation_executions_immutable ON coach_operation_executions;
  CREATE TRIGGER coach_operation_executions_immutable
  BEFORE UPDATE OR DELETE ON coach_operation_executions
  FOR EACH ROW
  EXECUTE FUNCTION prevent_coach_operation_execution_mutation()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION protect_cohort_rollout_identity()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'cohort rollouts cannot be deleted'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF (OLD.id, OLD.coach_workspace_id, OLD.cohort_id, OLD.target_cohort_release_id,
        OLD.baseline_cohort_release_id, OLD.planned_by_user_id, OLD.planned_by_role_snapshot, OLD.planned_at, OLD.created_at)
       IS DISTINCT FROM
       (NEW.id, NEW.coach_workspace_id, NEW.cohort_id, NEW.target_cohort_release_id,
        NEW.baseline_cohort_release_id, NEW.planned_by_user_id, NEW.planned_by_role_snapshot, NEW.planned_at, NEW.created_at) THEN
      RAISE EXCEPTION 'cohort rollout plan identity is immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollouts_protect_identity ON cohort_rollouts;
  CREATE TRIGGER cohort_rollouts_protect_identity
  BEFORE UPDATE OR DELETE ON cohort_rollouts
  FOR EACH ROW
  EXECUTE FUNCTION protect_cohort_rollout_identity()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION prevent_cohort_closure_with_open_rollout()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    IF NEW.status IN ('completed', 'archived')
       AND OLD.status IS DISTINCT FROM NEW.status
       AND EXISTS (
         SELECT 1 FROM cohort_rollouts
         WHERE cohort_id = NEW.id
           AND coach_workspace_id = NEW.coach_workspace_id
           AND status IN ('planned', 'active', 'paused')
       ) THEN
      RAISE EXCEPTION 'cohorts with an open rollout cannot be completed or archived'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohorts_open_rollout_lifecycle_guard ON cohorts;
  CREATE TRIGGER cohorts_open_rollout_lifecycle_guard
  BEFORE UPDATE OF status ON cohorts
  FOR EACH ROW
  EXECUTE FUNCTION prevent_cohort_closure_with_open_rollout()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION enforce_cohort_rollout_cohort_lifecycle()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  DECLARE
    cohort_status varchar;
  BEGIN
    SELECT status INTO cohort_status
    FROM cohorts
    WHERE id = NEW.cohort_id AND coach_workspace_id = NEW.coach_workspace_id
    FOR UPDATE;
    IF cohort_status IN ('completed', 'archived') THEN
      RAISE EXCEPTION 'cannot open a rollout for a completed or archived cohort'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollouts_cohort_lifecycle_guard ON cohort_rollouts;
  CREATE TRIGGER cohort_rollouts_cohort_lifecycle_guard
  BEFORE INSERT ON cohort_rollouts
  FOR EACH ROW
  EXECUTE FUNCTION enforce_cohort_rollout_cohort_lifecycle()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION prevent_cohort_rollout_wave_mutation()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    RAISE EXCEPTION 'cohort rollout waves are immutable'
      USING ERRCODE = 'integrity_constraint_violation';
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollout_waves_immutable ON cohort_rollout_waves;
  CREATE TRIGGER cohort_rollout_waves_immutable
  BEFORE UPDATE OR DELETE ON cohort_rollout_waves
  FOR EACH ROW
  EXECUTE FUNCTION prevent_cohort_rollout_wave_mutation()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION prevent_cohort_rollout_participant_mutation()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    RAISE EXCEPTION 'cohort rollout participants are immutable'
      USING ERRCODE = 'integrity_constraint_violation';
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollout_participants_immutable ON cohort_rollout_participants;
  CREATE TRIGGER cohort_rollout_participants_immutable
  BEFORE UPDATE OR DELETE ON cohort_rollout_participants
  FOR EACH ROW
  EXECUTE FUNCTION prevent_cohort_rollout_participant_mutation()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION enforce_cohort_rollout_participant_limit()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    PERFORM 1 FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id FOR UPDATE;
    IF (SELECT COUNT(*) FROM cohort_rollout_participants
        WHERE cohort_rollout_id = NEW.cohort_rollout_id) >= 500 THEN
      RAISE EXCEPTION 'cohort rollout plans support at most 500 participants'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollout_participants_limit ON cohort_rollout_participants;
  CREATE TRIGGER cohort_rollout_participants_limit
  BEFORE INSERT ON cohort_rollout_participants
  FOR EACH ROW
  EXECUTE FUNCTION enforce_cohort_rollout_participant_limit()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION prevent_cohort_rollout_plan_append()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    PERFORM 1 FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id FOR UPDATE;
    IF EXISTS (
      SELECT 1 FROM cohort_rollout_transitions
      WHERE cohort_rollout_id = NEW.cohort_rollout_id
    ) THEN
      RAISE EXCEPTION 'cohort rollout plan rows cannot be appended after planning completes'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollout_waves_prevent_append ON cohort_rollout_waves;
  CREATE TRIGGER cohort_rollout_waves_prevent_append
  BEFORE INSERT ON cohort_rollout_waves
  FOR EACH ROW
  EXECUTE FUNCTION prevent_cohort_rollout_plan_append()
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollout_participants_prevent_append ON cohort_rollout_participants;
  CREATE TRIGGER cohort_rollout_participants_prevent_append
  BEFORE INSERT ON cohort_rollout_participants
  FOR EACH ROW
  EXECUTE FUNCTION prevent_cohort_rollout_plan_append()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION prevent_cohort_rollout_transition_mutation()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
    RAISE EXCEPTION 'cohort rollout transitions are immutable'
      USING ERRCODE = 'integrity_constraint_violation';
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollout_transitions_immutable ON cohort_rollout_transitions;
  CREATE TRIGGER cohort_rollout_transitions_immutable
  BEFORE UPDATE OR DELETE ON cohort_rollout_transitions
  FOR EACH ROW
  EXECUTE FUNCTION prevent_cohort_rollout_transition_mutation()
SQL
execute <<~SQL
  CREATE OR REPLACE FUNCTION enforce_cohort_rollout_transition_append()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  DECLARE
    rollout_status varchar;
    rollout_wave_position integer;
    rollout_rollback_release_id bigint;
    previous_transition_id bigint;
    previous_status varchar;
    previous_wave_position integer;
  BEGIN
    SELECT status, current_wave_position, rollback_cohort_release_id
    INTO rollout_status, rollout_wave_position, rollout_rollback_release_id
    FROM cohort_rollouts
    WHERE id = NEW.cohort_rollout_id
    FOR UPDATE;

    SELECT id, to_status, to_wave_position
    INTO previous_transition_id, previous_status, previous_wave_position
    FROM cohort_rollout_transitions
    WHERE cohort_rollout_id = NEW.cohort_rollout_id
    ORDER BY id DESC
    LIMIT 1;

    IF previous_transition_id IS NULL THEN
      IF NEW.event_type <> 'planned' THEN
        RAISE EXCEPTION 'the first rollout transition must be planned'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
    ELSIF NEW.id <= previous_transition_id
       OR NEW.event_type = 'planned'
       OR NEW.from_status IS DISTINCT FROM previous_status
       OR NEW.from_wave_position IS DISTINCT FROM previous_wave_position THEN
      RAISE EXCEPTION 'rollout transitions must append one contiguous canonical tail'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF NEW.to_status IS DISTINCT FROM rollout_status
       OR NEW.to_wave_position IS DISTINCT FROM rollout_wave_position
       OR NEW.rollback_cohort_release_id IS DISTINCT FROM rollout_rollback_release_id THEN
      RAISE EXCEPTION 'appended rollout transition must match the current rollout state'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
  END;
  $$
SQL
execute <<~SQL
  DROP TRIGGER IF EXISTS cohort_rollout_transitions_enforce_append ON cohort_rollout_transitions;
  CREATE TRIGGER cohort_rollout_transitions_enforce_append
  BEFORE INSERT ON cohort_rollout_transitions
  FOR EACH ROW
  EXECUTE FUNCTION enforce_cohort_rollout_transition_append()
SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.validate_cohort_rollout_plan_integrity(checked_rollout_id bigint)
     RETURNS void
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      rollout_record cohort_rollouts%ROWTYPE;
      maximum_wave_position integer;
      wave_count integer;
    BEGIN
      SELECT * INTO rollout_record FROM cohort_rollouts WHERE id = checked_rollout_id;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      IF rollout_record.target_cohort_release_id IS DISTINCT FROM (
        SELECT release.id
        FROM cohort_releases release
        WHERE release.cohort_id = rollout_record.cohort_id
          AND release.coach_workspace_id = rollout_record.coach_workspace_id
        ORDER BY release.release_number DESC
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'planned rollout must target the latest sealed release'
          USING ERRCODE = 'check_violation',
            CONSTRAINT = 'cohort_rollout_target_is_latest_release';
      END IF;
      IF ARRAY(
        SELECT participant.user_id
        FROM cohort_rollout_participants participant
        WHERE participant.cohort_rollout_id = checked_rollout_id
        ORDER BY participant.user_id
      ) IS DISTINCT FROM ARRAY(
        SELECT membership.user_id
        FROM cohort_memberships membership
        WHERE membership.cohort_id = rollout_record.cohort_id
          AND membership.role = 'participant'
        ORDER BY membership.user_id
      ) THEN
        RAISE EXCEPTION 'planned rollout roster must exactly match current cohort participants'
          USING ERRCODE = 'check_violation',
            CONSTRAINT = 'cohort_rollout_roster_matches_current_participants';
      END IF;
      SELECT COUNT(*), MAX(position) INTO wave_count, maximum_wave_position
      FROM cohort_rollout_waves
      WHERE cohort_rollout_id = checked_rollout_id;
      IF wave_count < 1 OR wave_count > 25 OR maximum_wave_position IS DISTINCT FROM wave_count
         OR EXISTS (
           SELECT 1
           FROM cohort_rollout_waves wave
           WHERE wave.cohort_rollout_id = checked_rollout_id
             AND NOT EXISTS (
               SELECT 1
               FROM cohort_rollout_participants participant
               WHERE participant.cohort_rollout_wave_id = wave.id
             )
         ) THEN
        RAISE EXCEPTION 'rollout waves must be contiguous, bounded, and nonempty'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.validate_cohort_rollout_transition_integrity(checked_transition_id bigint)
     RETURNS void
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      rollout_record cohort_rollouts%ROWTYPE;
      transition_record cohort_rollout_transitions%ROWTYPE;
      previous_transition cohort_rollout_transitions%ROWTYPE;
      execution_record coach_operation_executions%ROWTYPE;
      previous_transition_id bigint := NULL;
      maximum_wave_position integer;
      execution_count integer;
      expected_operation_key varchar;
      planned_waves jsonb;
      expected_input jsonb;
      expected_before_snapshot jsonb;
      expected_predicted_snapshot jsonb;
      expected_after_snapshot jsonb;
    BEGIN
      SELECT * INTO transition_record
      FROM cohort_rollout_transitions
      WHERE id = checked_transition_id;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      SELECT * INTO rollout_record
      FROM cohort_rollouts
      WHERE id = transition_record.cohort_rollout_id;

      SELECT * INTO previous_transition
      FROM cohort_rollout_transitions
      WHERE cohort_rollout_id = transition_record.cohort_rollout_id
        AND id < transition_record.id
      ORDER BY id DESC
      LIMIT 1;
      IF FOUND THEN
        previous_transition_id := previous_transition.id;
        IF transition_record.event_type = 'planned'
           OR transition_record.from_status IS DISTINCT FROM previous_transition.to_status
           OR transition_record.from_wave_position IS DISTINCT FROM previous_transition.to_wave_position THEN
          RAISE EXCEPTION 'rollout transition does not append one contiguous state tail'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      ELSIF transition_record.event_type <> 'planned' THEN
        RAISE EXCEPTION 'the first rollout transition must be planned'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      SELECT MAX(position) INTO maximum_wave_position
      FROM cohort_rollout_waves
      WHERE cohort_rollout_id = transition_record.cohort_rollout_id;
      IF transition_record.to_wave_position > COALESCE(maximum_wave_position, 0) THEN
        RAISE EXCEPTION 'rollout transition references a wave outside the immutable plan'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF transition_record.event_type = 'completed'
         AND transition_record.to_wave_position IS DISTINCT FROM maximum_wave_position THEN
        RAISE EXCEPTION 'a rollout can complete only after its final wave'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF transition_record.event_type = 'rolled_back' AND NOT EXISTS (
        SELECT 1
        FROM cohort_releases rollback_release
        JOIN cohort_releases target_release
          ON target_release.id = rollout_record.target_cohort_release_id
        WHERE rollback_release.id = transition_record.rollback_cohort_release_id
          AND rollback_release.release_number < target_release.release_number
      ) THEN
        RAISE EXCEPTION 'rollback release must predate the rollout target release'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF transition_record.event_type = 'planned'
         AND (transition_record.actor_user_id IS DISTINCT FROM rollout_record.planned_by_user_id
           OR transition_record.actor_role_snapshot IS DISTINCT FROM rollout_record.planned_by_role_snapshot) THEN
        RAISE EXCEPTION 'planned rollout attribution must match the immutable planner'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      SELECT COUNT(*) INTO execution_count
      FROM coach_operation_executions
      WHERE cohort_rollout_transition_id = transition_record.id;
      IF execution_count <> 1 THEN
        RAISE EXCEPTION 'every rollout transition must have exactly one coach operation execution'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      SELECT * INTO execution_record
      FROM coach_operation_executions
      WHERE cohort_rollout_transition_id = transition_record.id;

      expected_operation_key := CASE transition_record.event_type
        WHEN 'planned' THEN 'cohort.rollout.plan'
        WHEN 'activated' THEN 'cohort.rollout.advance'
        WHEN 'advanced' THEN 'cohort.rollout.advance'
        WHEN 'completed' THEN 'cohort.rollout.advance'
        WHEN 'paused' THEN 'cohort.rollout.pause'
        WHEN 'resumed' THEN 'cohort.rollout.resume'
        WHEN 'cancelled' THEN 'cohort.rollout.cancel'
        WHEN 'rolled_back' THEN 'cohort.rollout.rollback'
      END;
      IF execution_record.operation_key IS DISTINCT FROM expected_operation_key
         OR execution_record.actor_user_id IS DISTINCT FROM transition_record.actor_user_id
         OR execution_record.actor_role_snapshot IS DISTINCT FROM transition_record.actor_role_snapshot
         OR execution_record.completed_at IS DISTINCT FROM transition_record.occurred_at THEN
        RAISE EXCEPTION 'rollout operation identity does not match its transition'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF transition_record.event_type = 'planned' THEN
        SELECT COALESCE(jsonb_agg(
          jsonb_build_object(
            'name', wave.name,
            'user_ids', COALESCE((
              SELECT jsonb_agg(participant.user_id ORDER BY participant.user_id)
              FROM cohort_rollout_participants participant
              WHERE participant.cohort_rollout_wave_id = wave.id
            ), '[]'::jsonb)
          ) ORDER BY wave.position
        ), '[]'::jsonb)
        INTO planned_waves
        FROM cohort_rollout_waves wave
        WHERE wave.cohort_rollout_id = transition_record.cohort_rollout_id;
        expected_input := jsonb_build_object(
          'target_release_id', rollout_record.target_cohort_release_id,
          'expected_latest_release_id', rollout_record.target_cohort_release_id,
          'expected_roster_digest', execution_record.normalized_input->>'expected_roster_digest',
          'waves', planned_waves
        );
        IF execution_record.normalized_input IS DISTINCT FROM expected_input
           OR (execution_record.normalized_input->>'expected_roster_digest') !~ '^[0-9a-f]{64}$' THEN
          RAISE EXCEPTION 'planned rollout input does not match the immutable plan'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      ELSE
        expected_input := jsonb_build_object(
          'rollout_id', transition_record.cohort_rollout_id,
          'expected_status', transition_record.from_status,
          'expected_current_wave_position', transition_record.from_wave_position,
          'expected_latest_transition_id', previous_transition_id
        );
        IF transition_record.event_type IN ('activated', 'advanced', 'completed') THEN
          expected_input := expected_input || jsonb_build_object('readiness_digest', transition_record.readiness_digest);
        ELSIF transition_record.event_type = 'rolled_back' THEN
          expected_input := expected_input || jsonb_build_object(
            'rollback_release_id', transition_record.rollback_cohort_release_id
          );
        END IF;
        IF execution_record.normalized_input IS DISTINCT FROM expected_input THEN
          RAISE EXCEPTION 'rollout transition input does not match its immutable CAS evidence'
            USING ERRCODE = 'integrity_constraint_violation',
              DETAIL = format(
                'transition_id=%s expected=%s actual=%s',
                transition_record.id,
                expected_input,
                execution_record.normalized_input
              );
        END IF;
      END IF;

      IF (execution_record.operation_version = 2) IS DISTINCT FROM
       (rollout_record.baseline_cohort_release_id IS NOT NULL) THEN
      RAISE EXCEPTION 'rollout operation version must match its runtime mode'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF execution_record.operation_version = 2 THEN
        IF rollout_record.baseline_cohort_release_id IS NULL
           OR rollout_record.baseline_cohort_release_id = rollout_record.target_cohort_release_id THEN
          RAISE EXCEPTION 'runtime rollout must capture a distinct baseline release'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF transition_record.participant_runtime_changed IS DISTINCT FROM
           (transition_record.event_type IN ('activated', 'advanced', 'completed', 'rolled_back')) THEN
          RAISE EXCEPTION 'runtime change evidence does not match the v2 rollout event'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF transition_record.event_type = 'planned' THEN
          expected_before_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v2',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', NULL,
            'status', NULL,
            'current_wave_position', NULL,
            'latest_transition_id', NULL,
            'target_release_id', NULL,
            'rollback_release_id', NULL,
            'latest_release_id', rollout_record.target_cohort_release_id,
            'participant_roster_digest', execution_record.normalized_input->>'expected_roster_digest',
            'participant_runtime_changed', false,
            'active_release_id', rollout_record.baseline_cohort_release_id,
            'baseline_release_id', rollout_record.baseline_cohort_release_id
          );
          expected_predicted_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v2',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', NULL,
            'status', transition_record.to_status,
            'current_wave_position', transition_record.to_wave_position,
            'latest_transition_id', NULL,
            'target_release_id', rollout_record.target_cohort_release_id,
            'rollback_release_id', NULL,
            'participant_runtime_changed', false,
            'active_release_id', rollout_record.baseline_cohort_release_id,
            'baseline_release_id', rollout_record.baseline_cohort_release_id,
            'latest_transition_id_pending', true,
            'rollout_id_pending', true
          );
        ELSE
          expected_before_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v2',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', transition_record.cohort_rollout_id,
            'status', transition_record.from_status,
            'current_wave_position', transition_record.from_wave_position,
            'latest_transition_id', previous_transition_id,
            'target_release_id', rollout_record.target_cohort_release_id,
            'rollback_release_id', NULL,
            'participant_runtime_changed', false,
            'active_release_id', rollout_record.baseline_cohort_release_id,
            'baseline_release_id', rollout_record.baseline_cohort_release_id
          );
          IF transition_record.event_type IN ('activated', 'advanced', 'completed') THEN
            expected_before_snapshot := expected_before_snapshot ||
              jsonb_build_object('readiness_digest', transition_record.readiness_digest);
          END IF;
          expected_predicted_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v2',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', transition_record.cohort_rollout_id,
            'status', transition_record.to_status,
            'current_wave_position', transition_record.to_wave_position,
            'latest_transition_id', NULL,
            'target_release_id', rollout_record.target_cohort_release_id,
            'rollback_release_id', transition_record.rollback_cohort_release_id,
            'participant_runtime_changed', transition_record.participant_runtime_changed,
            'active_release_id', CASE WHEN transition_record.to_status = 'completed'
              THEN rollout_record.target_cohort_release_id ELSE rollout_record.baseline_cohort_release_id END,
            'baseline_release_id', rollout_record.baseline_cohort_release_id,
            'latest_transition_id_pending', true
          );
        END IF;
        expected_after_snapshot := jsonb_build_object(
          'schema', 'cohort_rollout_state_v2',
          'cohort_id', rollout_record.cohort_id,
          'coach_workspace_id', rollout_record.coach_workspace_id,
          'rollout_id', transition_record.cohort_rollout_id,
          'status', transition_record.to_status,
          'current_wave_position', transition_record.to_wave_position,
          'latest_transition_id', transition_record.id,
          'target_release_id', rollout_record.target_cohort_release_id,
          'rollback_release_id', transition_record.rollback_cohort_release_id,
          'participant_runtime_changed', transition_record.participant_runtime_changed,
          'active_release_id', CASE WHEN transition_record.to_status = 'completed'
            THEN rollout_record.target_cohort_release_id ELSE rollout_record.baseline_cohort_release_id END,
          'baseline_release_id', rollout_record.baseline_cohort_release_id
        );
        IF execution_record.before_snapshot IS DISTINCT FROM expected_before_snapshot
           OR execution_record.predicted_after_snapshot IS DISTINCT FROM expected_predicted_snapshot
           OR execution_record.after_snapshot IS DISTINCT FROM expected_after_snapshot THEN
          RAISE EXCEPTION 'v2 rollout snapshots do not match runtime evidence'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF transition_record.event_type = 'planned' THEN
          IF rollout_record.baseline_cohort_release_id IS DISTINCT FROM (
            SELECT active_cohort_release_id FROM cohorts WHERE id = rollout_record.cohort_id
          ) THEN
            RAISE EXCEPTION 'runtime rollout baseline must match the active cohort release'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSIF transition_record.event_type IN ('activated', 'advanced', 'completed') AND EXISTS (
          SELECT 1
          FROM cohort_rollout_participants participant
          LEFT JOIN cohort_memberships membership
            ON membership.id = participant.cohort_membership_id
           AND membership.cohort_id = participant.cohort_id
           AND membership.user_id = participant.user_id
           AND membership.role = 'participant'
           AND membership.created_at = participant.membership_started_at
          WHERE participant.cohort_rollout_id = rollout_record.id
            AND membership.id IS NULL
        ) THEN
          RAISE EXCEPTION 'runtime rollout participant enrollment changed after planning'
            USING ERRCODE = 'integrity_constraint_violation';
        ELSIF transition_record.event_type IN ('activated', 'advanced') THEN
          IF EXISTS (
               SELECT 1 FROM cohort_release_exposures exposure
               LEFT JOIN cohort_rollout_participants participant
                 ON participant.cohort_rollout_id = rollout_record.id
                AND participant.user_id = exposure.user_id
                AND participant.cohort_rollout_wave_id = exposure.cohort_rollout_wave_id
               LEFT JOIN cohort_rollout_waves wave
                 ON wave.id = participant.cohort_rollout_wave_id
                AND wave.cohort_rollout_id = rollout_record.id
               WHERE exposure.cohort_rollout_transition_id = transition_record.id
                 AND (exposure.event_type <> 'wave'
                   OR exposure.cohort_release_id <> rollout_record.target_cohort_release_id
                   OR participant.id IS NULL
                   OR wave.position <> transition_record.to_wave_position)
             ) OR EXISTS (
               SELECT 1 FROM cohort_rollout_participants participant
               JOIN cohort_rollout_waves wave ON wave.id = participant.cohort_rollout_wave_id
               LEFT JOIN cohort_release_exposures exposure
                 ON exposure.cohort_rollout_transition_id = transition_record.id
                AND exposure.user_id = participant.user_id
                AND exposure.cohort_rollout_wave_id = wave.id
                AND exposure.event_type = 'wave'
                AND exposure.cohort_release_id = rollout_record.target_cohort_release_id
               WHERE participant.cohort_rollout_id = rollout_record.id
                 AND wave.position = transition_record.to_wave_position
                 AND exposure.id IS NULL
             ) THEN
            RAISE EXCEPTION 'runtime rollout wave exposure is incomplete'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSIF transition_record.event_type = 'completed' THEN
          IF (SELECT active_cohort_release_id FROM cohorts WHERE id = rollout_record.cohort_id)
               IS DISTINCT FROM rollout_record.target_cohort_release_id
             OR NOT EXISTS (
               SELECT 1 FROM cohort_release_activation_events event
               WHERE event.cohort_rollout_transition_id = transition_record.id
                 AND event.to_cohort_release_id = rollout_record.target_cohort_release_id
             ) THEN
            RAISE EXCEPTION 'completed runtime rollout must activate its target release'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSIF transition_record.event_type = 'rolled_back' THEN
          IF transition_record.rollback_cohort_release_id IS DISTINCT FROM rollout_record.baseline_cohort_release_id
             OR EXISTS (
               SELECT 1 FROM cohort_release_exposures exposure
               WHERE exposure.cohort_rollout_transition_id = transition_record.id
                 AND (exposure.event_type <> 'rollback'
                   OR exposure.cohort_release_id <> rollout_record.baseline_cohort_release_id
                   OR NOT EXISTS (
                     SELECT 1
                     FROM cohort_rollout_participants participant
                     JOIN cohort_release_exposures prior
                       ON prior.cohort_rollout_id = rollout_record.id
                      AND prior.event_type = 'wave'
                      AND prior.user_id = participant.user_id
                      AND prior.cohort_rollout_wave_id = participant.cohort_rollout_wave_id
                      AND prior.cohort_membership_id = participant.cohort_membership_id
                      AND prior.membership_started_at = participant.membership_started_at
                     JOIN cohort_memberships membership
                       ON membership.id = participant.cohort_membership_id
                      AND membership.cohort_id = participant.cohort_id
                      AND membership.user_id = participant.user_id
                      AND membership.role = 'participant'
                      AND membership.created_at = participant.membership_started_at
                     WHERE participant.cohort_rollout_id = rollout_record.id
                       AND participant.user_id = exposure.user_id
                       AND participant.cohort_rollout_wave_id = exposure.cohort_rollout_wave_id
                       AND participant.cohort_membership_id = exposure.cohort_membership_id
                       AND participant.membership_started_at = exposure.membership_started_at
                   ))
             ) OR EXISTS (
               SELECT DISTINCT prior.user_id
               FROM cohort_release_exposures prior
               JOIN cohort_rollout_participants participant
                 ON participant.cohort_rollout_id = rollout_record.id
                AND participant.user_id = prior.user_id
                AND participant.cohort_rollout_wave_id = prior.cohort_rollout_wave_id
                AND participant.cohort_membership_id = prior.cohort_membership_id
                AND participant.membership_started_at = prior.membership_started_at
               JOIN cohort_memberships membership
                 ON membership.id = participant.cohort_membership_id
                AND membership.cohort_id = participant.cohort_id
                AND membership.user_id = participant.user_id
                AND membership.role = 'participant'
                AND membership.created_at = participant.membership_started_at
               LEFT JOIN cohort_release_exposures restored
                 ON restored.cohort_rollout_transition_id = transition_record.id
                AND restored.user_id = prior.user_id
                AND restored.cohort_rollout_wave_id = prior.cohort_rollout_wave_id
                AND restored.cohort_membership_id = prior.cohort_membership_id
                AND restored.membership_started_at = prior.membership_started_at
                AND restored.event_type = 'rollback'
                AND restored.cohort_release_id = rollout_record.baseline_cohort_release_id
               WHERE prior.cohort_rollout_id = rollout_record.id
                 AND prior.event_type = 'wave'
                 AND restored.id IS NULL
             ) THEN
            RAISE EXCEPTION 'runtime rollback must restore the captured baseline'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END IF;
        RETURN;
      END IF;

    IF transition_record.event_type = 'planned' THEN
        expected_before_snapshot := jsonb_build_object(
          'schema', 'cohort_rollout_state_v1',
          'cohort_id', rollout_record.cohort_id,
          'coach_workspace_id', rollout_record.coach_workspace_id,
          'rollout_id', NULL,
          'status', NULL,
          'current_wave_position', NULL,
          'latest_transition_id', NULL,
          'target_release_id', NULL,
          'rollback_release_id', NULL,
          'latest_release_id', rollout_record.target_cohort_release_id,
          'participant_roster_digest', execution_record.normalized_input->>'expected_roster_digest',
          'participant_runtime_changed', false
        );
        expected_predicted_snapshot := jsonb_build_object(
          'schema', 'cohort_rollout_state_v1',
          'cohort_id', rollout_record.cohort_id,
          'coach_workspace_id', rollout_record.coach_workspace_id,
          'rollout_id', NULL,
          'rollout_id_pending', true,
          'status', transition_record.to_status,
          'current_wave_position', transition_record.to_wave_position,
          'latest_transition_id', NULL,
          'latest_transition_id_pending', true,
          'target_release_id', rollout_record.target_cohort_release_id,
          'rollback_release_id', transition_record.rollback_cohort_release_id,
          'participant_runtime_changed', false
        );
      ELSE
        expected_before_snapshot := jsonb_build_object(
          'schema', 'cohort_rollout_state_v1',
          'cohort_id', rollout_record.cohort_id,
          'coach_workspace_id', rollout_record.coach_workspace_id,
          'rollout_id', transition_record.cohort_rollout_id,
          'status', transition_record.from_status,
          'current_wave_position', transition_record.from_wave_position,
          'latest_transition_id', previous_transition_id,
          'target_release_id', rollout_record.target_cohort_release_id,
          'rollback_release_id', NULL,
          'participant_runtime_changed', false
        );
        IF transition_record.event_type IN ('activated', 'advanced', 'completed') THEN
          expected_before_snapshot := expected_before_snapshot ||
            jsonb_build_object('readiness_digest', transition_record.readiness_digest);
        END IF;
        expected_predicted_snapshot := jsonb_build_object(
          'schema', 'cohort_rollout_state_v1',
          'cohort_id', rollout_record.cohort_id,
          'coach_workspace_id', rollout_record.coach_workspace_id,
          'rollout_id', transition_record.cohort_rollout_id,
          'status', transition_record.to_status,
          'current_wave_position', transition_record.to_wave_position,
          'latest_transition_id', NULL,
          'latest_transition_id_pending', true,
          'target_release_id', rollout_record.target_cohort_release_id,
          'rollback_release_id', transition_record.rollback_cohort_release_id,
          'participant_runtime_changed', false
        );
      END IF;

      expected_after_snapshot := jsonb_build_object(
        'schema', 'cohort_rollout_state_v1',
        'cohort_id', rollout_record.cohort_id,
        'coach_workspace_id', rollout_record.coach_workspace_id,
        'rollout_id', transition_record.cohort_rollout_id,
        'status', transition_record.to_status,
        'current_wave_position', transition_record.to_wave_position,
        'latest_transition_id', transition_record.id,
        'target_release_id', rollout_record.target_cohort_release_id,
        'rollback_release_id', transition_record.rollback_cohort_release_id,
        'participant_runtime_changed', false
      );
      IF execution_record.before_snapshot IS DISTINCT FROM expected_before_snapshot
         OR execution_record.predicted_after_snapshot IS DISTINCT FROM expected_predicted_snapshot
         OR execution_record.after_snapshot IS DISTINCT FROM expected_after_snapshot THEN
        RAISE EXCEPTION 'rollout operation snapshots do not match exact relational evidence'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.validate_cohort_rollout_latest_integrity(checked_rollout_id bigint)
     RETURNS void
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      rollout_record cohort_rollouts%ROWTYPE;
      latest_transition cohort_rollout_transitions%ROWTYPE;
      previous_transition cohort_rollout_transitions%ROWTYPE;
      planned_occurred_at timestamp := NULL;
      activated_occurred_at timestamp := NULL;
      expected_paused_at timestamp := NULL;
    BEGIN
      SELECT * INTO rollout_record FROM cohort_rollouts WHERE id = checked_rollout_id;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      SELECT * INTO latest_transition
      FROM cohort_rollout_transitions
      WHERE cohort_rollout_id = checked_rollout_id
      ORDER BY id DESC
      LIMIT 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'every rollout must have transition history'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF rollout_record.status IS DISTINCT FROM latest_transition.to_status
         OR rollout_record.current_wave_position IS DISTINCT FROM latest_transition.to_wave_position
         OR rollout_record.rollback_cohort_release_id IS DISTINCT FROM latest_transition.rollback_cohort_release_id THEN
        RAISE EXCEPTION 'rollout state must match its latest transition'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      SELECT occurred_at INTO planned_occurred_at
      FROM cohort_rollout_transitions
      WHERE cohort_rollout_id = checked_rollout_id AND event_type = 'planned'
      ORDER BY id
      LIMIT 1;
      SELECT occurred_at INTO activated_occurred_at
      FROM cohort_rollout_transitions
      WHERE cohort_rollout_id = checked_rollout_id AND event_type = 'activated'
      ORDER BY id
      LIMIT 1;
      IF rollout_record.status = 'paused' THEN
        expected_paused_at := latest_transition.occurred_at;
      ELSIF rollout_record.status = 'rolled_back' AND latest_transition.from_status = 'paused' THEN
        SELECT * INTO previous_transition
        FROM cohort_rollout_transitions
        WHERE cohort_rollout_id = checked_rollout_id AND id < latest_transition.id
        ORDER BY id DESC
        LIMIT 1;
        expected_paused_at := previous_transition.occurred_at;
      END IF;

      IF rollout_record.planned_at IS DISTINCT FROM planned_occurred_at
         OR rollout_record.activated_at IS DISTINCT FROM activated_occurred_at
         OR rollout_record.paused_at IS DISTINCT FROM expected_paused_at THEN
        RAISE EXCEPTION 'rollout lifecycle timestamps must match transition history'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF (rollout_record.status = 'completed' AND rollout_record.completed_at IS DISTINCT FROM latest_transition.occurred_at)
         OR (rollout_record.status <> 'completed' AND rollout_record.completed_at IS NOT NULL)
         OR (rollout_record.status = 'cancelled' AND rollout_record.cancelled_at IS DISTINCT FROM latest_transition.occurred_at)
         OR (rollout_record.status <> 'cancelled' AND rollout_record.cancelled_at IS NOT NULL)
         OR (rollout_record.status = 'rolled_back' AND rollout_record.rolled_back_at IS DISTINCT FROM latest_transition.occurred_at)
         OR (rollout_record.status <> 'rolled_back' AND rollout_record.rolled_back_at IS NOT NULL) THEN
        RAISE EXCEPTION 'rollout terminal timestamps must match the terminal transition'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.check_cohort_rollout_row_integrity()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        PERFORM validate_cohort_rollout_plan_integrity(NEW.id);
      END IF;
      PERFORM validate_cohort_rollout_latest_integrity(COALESCE(NEW.id, OLD.id));
      RETURN NULL;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.check_cohort_rollout_transition_integrity()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      PERFORM validate_cohort_rollout_transition_integrity(COALESCE(NEW.id, OLD.id));
      PERFORM validate_cohort_rollout_latest_integrity(COALESCE(NEW.cohort_rollout_id, OLD.cohort_rollout_id));
      RETURN NULL;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.check_cohort_rollout_execution_integrity()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF COALESCE(NEW.cohort_rollout_transition_id, OLD.cohort_rollout_transition_id) IS NULL THEN
        RETURN NULL;
      END IF;
      PERFORM validate_cohort_rollout_transition_integrity(
        COALESCE(NEW.cohort_rollout_transition_id, OLD.cohort_rollout_transition_id)
      );
      RETURN NULL;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE CONSTRAINT TRIGGER cohort_rollouts_integrity_deferred AFTER INSERT OR DELETE OR UPDATE ON public.cohort_rollouts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_cohort_rollout_row_integrity();
  SQL
  execute <<~'SQL'
    CREATE CONSTRAINT TRIGGER cohort_rollout_transitions_integrity_deferred AFTER INSERT OR DELETE OR UPDATE ON public.cohort_rollout_transitions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_cohort_rollout_transition_integrity();
  SQL
  execute <<~'SQL'
    CREATE CONSTRAINT TRIGGER coach_operation_rollout_integrity_deferred AFTER INSERT OR DELETE OR UPDATE ON public.coach_operation_executions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_cohort_rollout_execution_integrity();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.prevent_cohort_runtime_evidence_mutation()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION 'cohort runtime evidence is append-only'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.enforce_cohort_runtime_scope()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.active_cohort_release_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM cohort_releases
        WHERE id = NEW.active_cohort_release_id
          AND cohort_id = NEW.id
          AND coach_workspace_id = NEW.coach_workspace_id
      ) THEN
        RAISE EXCEPTION 'active cohort release must belong to the cohort and workspace'
          USING ERRCODE = 'foreign_key_violation';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.enforce_cohort_release_exposure_membership_epoch()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM cohort_memberships membership
        WHERE membership.id = NEW.cohort_membership_id
          AND membership.cohort_id = NEW.cohort_id
          AND membership.user_id = NEW.user_id
          AND membership.role = 'participant'
          AND membership.created_at = NEW.membership_started_at
      ) THEN
        RAISE EXCEPTION 'release exposure must reference the current participant membership epoch'
          USING ERRCODE = 'foreign_key_violation';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.enforce_cohort_rollout_participant_membership_epoch()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      runtime_rollout boolean;
    BEGIN
      SELECT baseline_cohort_release_id IS NOT NULL INTO runtime_rollout
      FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id;
      IF runtime_rollout AND NOT EXISTS (
        SELECT 1 FROM cohort_memberships membership
        WHERE membership.id = NEW.cohort_membership_id
          AND membership.cohort_id = NEW.cohort_id
          AND membership.user_id = NEW.user_id
          AND membership.role = 'participant'
          AND membership.created_at = NEW.membership_started_at
      ) THEN
        RAISE EXCEPTION 'runtime rollout participants must pin the current participant membership epoch'
          USING ERRCODE = 'foreign_key_violation';
      ELSIF NOT runtime_rollout AND
        (NEW.cohort_membership_id IS NOT NULL OR NEW.membership_started_at IS NOT NULL) THEN
        RAISE EXCEPTION 'legacy rollout participants cannot claim runtime membership evidence'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.mark_cohort_runtime_transition_pending()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      validation_key text;
    BEGIN
      IF NEW.cohort_rollout_transition_id IS NOT NULL THEN
        validation_key := format(
          'household_cfo.runtime_transition_%s',
          NEW.cohort_rollout_transition_id
        );
        PERFORM set_config(validation_key, 'pending', true);
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.prepare_cohort_release_activation_event()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      current_release_id bigint;
      rollout_record cohort_rollouts%ROWTYPE;
      transition_record cohort_rollout_transitions%ROWTYPE;
    BEGIN
      SELECT active_cohort_release_id INTO current_release_id
      FROM cohorts
      WHERE id = NEW.cohort_id AND coach_workspace_id = NEW.coach_workspace_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'release activation cohort does not exist in the claimed workspace'
          USING ERRCODE = 'foreign_key_violation';
      END IF;
      IF current_release_id IS DISTINCT FROM NEW.from_cohort_release_id THEN
        RAISE EXCEPTION 'release activation evidence must start from the current cohort release'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF NEW.event_type IN ('backfill', 'initial_launch') THEN
        IF NEW.from_cohort_release_id IS NOT NULL THEN
          RAISE EXCEPTION 'initial activation requires a cohort without an active release'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      ELSIF NEW.event_type = 'rollout_completed' THEN
        SELECT * INTO rollout_record FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id;
        SELECT * INTO transition_record FROM cohort_rollout_transitions WHERE id = NEW.cohort_rollout_transition_id;
        IF rollout_record.id IS NULL
           OR transition_record.id IS NULL
           OR transition_record.cohort_rollout_id <> rollout_record.id
           OR transition_record.event_type <> 'completed'
           OR rollout_record.baseline_cohort_release_id IS DISTINCT FROM NEW.from_cohort_release_id
           OR rollout_record.target_cohort_release_id IS DISTINCT FROM NEW.to_cohort_release_id
           OR transition_record.actor_user_id IS DISTINCT FROM NEW.actor_user_id
           OR transition_record.actor_role_snapshot IS DISTINCT FROM NEW.actor_role_snapshot
           OR transition_record.occurred_at IS DISTINCT FROM NEW.occurred_at THEN
          RAISE EXCEPTION 'rollout activation evidence must match its completed transition and release change'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;

      NEW.database_transaction_id := txid_current();
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.check_cohort_active_release_change_integrity()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      matching_events integer;
    BEGIN
      IF OLD.active_cohort_release_id IS NOT DISTINCT FROM NEW.active_cohort_release_id THEN
        RETURN NULL;
      END IF;

      SELECT count(*) INTO matching_events
      FROM cohort_release_activation_events event
      WHERE event.cohort_id = NEW.id
        AND event.coach_workspace_id = NEW.coach_workspace_id
        AND event.from_cohort_release_id IS NOT DISTINCT FROM OLD.active_cohort_release_id
        AND event.to_cohort_release_id = NEW.active_cohort_release_id
        AND event.database_transaction_id = txid_current();

      IF matching_events <> 1 THEN
        RAISE EXCEPTION 'active cohort release changes require exactly one matching activation event in the same transaction'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NULL;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.check_cohort_runtime_evidence_integrity()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      active_release_id bigint;
      validation_key text;
    BEGIN
      IF TG_TABLE_NAME = 'cohort_release_activation_events' THEN
        SELECT cohorts.active_cohort_release_id INTO active_release_id
        FROM cohorts WHERE cohorts.id = NEW.cohort_id;
        IF active_release_id IS DISTINCT FROM NEW.to_cohort_release_id
           OR NEW.database_transaction_id <> txid_current() THEN
          RAISE EXCEPTION 'release activation evidence must match the resulting cohort pointer in the same transaction'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;
      IF NEW.cohort_rollout_transition_id IS NOT NULL THEN
        validation_key := format(
          'household_cfo.runtime_transition_%s',
          NEW.cohort_rollout_transition_id
        );
        IF current_setting(validation_key, true) IS DISTINCT FROM txid_current()::text THEN
          PERFORM validate_cohort_rollout_transition_integrity(NEW.cohort_rollout_transition_id);
          PERFORM set_config(validation_key, txid_current()::text, true);
        END IF;
      END IF;
      RETURN NULL;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_release_exposures_immutable BEFORE DELETE OR UPDATE ON public.cohort_release_exposures FOR EACH ROW EXECUTE FUNCTION prevent_cohort_runtime_evidence_mutation();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_release_activation_events_immutable BEFORE DELETE OR UPDATE ON public.cohort_release_activation_events FOR EACH ROW EXECUTE FUNCTION prevent_cohort_runtime_evidence_mutation();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_runtime_scope_guard BEFORE INSERT OR UPDATE OF active_cohort_release_id, coach_workspace_id ON public.cohorts FOR EACH ROW EXECUTE FUNCTION enforce_cohort_runtime_scope();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_release_exposures_membership_epoch_guard BEFORE INSERT ON public.cohort_release_exposures FOR EACH ROW EXECUTE FUNCTION enforce_cohort_release_exposure_membership_epoch();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_rollout_participants_membership_epoch_guard BEFORE INSERT ON public.cohort_rollout_participants FOR EACH ROW EXECUTE FUNCTION enforce_cohort_rollout_participant_membership_epoch();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_release_exposures_transition_pending BEFORE INSERT ON public.cohort_release_exposures FOR EACH ROW EXECUTE FUNCTION mark_cohort_runtime_transition_pending();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_release_activation_events_transition_pending BEFORE INSERT ON public.cohort_release_activation_events FOR EACH ROW EXECUTE FUNCTION mark_cohort_runtime_transition_pending();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER cohort_release_activation_events_prepare BEFORE INSERT ON public.cohort_release_activation_events FOR EACH ROW EXECUTE FUNCTION prepare_cohort_release_activation_event();
  SQL
  execute <<~'SQL'
    CREATE CONSTRAINT TRIGGER cohort_active_release_change_integrity_deferred AFTER UPDATE OF active_cohort_release_id ON public.cohorts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_cohort_active_release_change_integrity();
  SQL
  execute <<~'SQL'
    CREATE CONSTRAINT TRIGGER cohort_release_exposures_integrity_deferred AFTER INSERT ON public.cohort_release_exposures DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_cohort_runtime_evidence_integrity();
  SQL
  execute <<~'SQL'
    CREATE CONSTRAINT TRIGGER cohort_release_activation_events_integrity_deferred AFTER INSERT ON public.cohort_release_activation_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_cohort_runtime_evidence_integrity();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.prevent_workspace_brand_evidence_mutation()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION 'workspace brand evidence is immutable';
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.prevent_verified_workspace_domain_identity_change()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF (NEW.hostname IS DISTINCT FROM OLD.hostname OR NEW.kind IS DISTINCT FROM OLD.kind)
        AND (
          OLD.verification_requested_at IS NOT NULL
          OR OLD.verified_at IS NOT NULL
          OR OLD.activated_at IS NOT NULL
          OR OLD.status <> 'pending'
        )
      THEN
        RAISE EXCEPTION 'verified workspace domain identity cannot change';
      END IF;
      RETURN NEW;
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER workspace_brand_versions_immutable BEFORE DELETE OR UPDATE ON public.workspace_brand_versions FOR EACH ROW EXECUTE FUNCTION prevent_workspace_brand_evidence_mutation();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER workspace_brand_publication_events_immutable BEFORE DELETE OR UPDATE ON public.workspace_brand_publication_events FOR EACH ROW EXECUTE FUNCTION prevent_workspace_brand_evidence_mutation();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER coach_workspace_domain_events_immutable BEFORE DELETE OR UPDATE ON public.coach_workspace_domain_events FOR EACH ROW EXECUTE FUNCTION prevent_workspace_brand_evidence_mutation();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER coach_workspace_domains_verified_identity BEFORE UPDATE ON public.coach_workspace_domains FOR EACH ROW EXECUTE FUNCTION prevent_verified_workspace_domain_identity_change();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.prevent_workspace_membership_event_mutation()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION 'collaborator access history cannot be changed or deleted'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER workspace_membership_events_immutable BEFORE DELETE OR UPDATE ON public.coach_workspace_membership_events FOR EACH ROW EXECUTE FUNCTION prevent_workspace_membership_event_mutation();
  SQL
  execute <<~SQL
    CREATE OR REPLACE FUNCTION public.challenge_reminder_identity_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF TG_TABLE_NAME = 'challenge_reminder_preferences' THEN
        IF TG_OP = 'UPDATE' AND NEW.channel IS DISTINCT FROM OLD.channel THEN RAISE EXCEPTION 'reminder channel is immutable'; END IF;
      ELSE
        IF NOT EXISTS (SELECT 1 FROM challenge_reminder_preferences p WHERE p.id = NEW.challenge_reminder_preference_id AND p.savings_enrollment_id = NEW.savings_enrollment_id AND p.channel = NEW.channel) THEN RAISE EXCEPTION 'reminder preference scope mismatch'; END IF;
        IF TG_OP = 'UPDATE' AND (NEW.channel, NEW.local_on, NEW.delivery_key, NEW.challenge_reminder_preference_id) IS DISTINCT FROM (OLD.channel, OLD.local_on, OLD.delivery_key, OLD.challenge_reminder_preference_id) THEN RAISE EXCEPTION 'reminder delivery identity is immutable'; END IF;
        IF TG_OP = 'UPDATE' AND OLD.status IN ('delivered','cancelled','failed','unknown') AND NEW.status IS DISTINCT FROM OLD.status THEN RAISE EXCEPTION 'terminal reminder cannot be resent'; END IF;
        IF TG_OP = 'UPDATE' AND OLD.provider_namespace IS NOT NULL AND (NEW.provider_namespace, NEW.provider_idempotent) IS DISTINCT FROM (OLD.provider_namespace, OLD.provider_idempotent) THEN RAISE EXCEPTION 'provider delivery identity is immutable'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_reminder_preferences_identity BEFORE INSERT OR UPDATE ON public.challenge_reminder_preferences FOR EACH ROW EXECUTE FUNCTION challenge_reminder_identity_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_reminders_identity BEFORE INSERT OR UPDATE ON public.challenge_reminders FOR EACH ROW EXECUTE FUNCTION challenge_reminder_identity_guard();
  SQL
  execute <<~SQL
    CREATE OR REPLACE FUNCTION public.challenge_privacy_scope_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE enrollment savings_enrollments;
    BEGIN
      SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
      IF NEW.household_id <> enrollment.household_id OR NEW.participant_user_id <> enrollment.user_id THEN
        RAISE EXCEPTION 'challenge privacy participant scope' USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF TG_OP = 'UPDATE' AND (NEW.household_id, NEW.participant_user_id, NEW.savings_enrollment_id) IS DISTINCT FROM (OLD.household_id, OLD.participant_user_id, OLD.savings_enrollment_id) THEN
        RAISE EXCEPTION 'challenge privacy identity is immutable';
      END IF;
      IF TG_TABLE_NAME = 'challenge_privacy_grants' AND TG_OP = 'UPDATE' THEN
        IF (NEW.kind, NEW.recipient_user_id) IS DISTINCT FROM (OLD.kind, OLD.recipient_user_id) THEN RAISE EXCEPTION 'sharing recipient and purpose are immutable'; END IF;
      ELSIF TG_TABLE_NAME = 'challenge_support_tickets' AND TG_OP = 'UPDATE' THEN
        IF (NEW.recipient_user_id, NEW.issue_kind, NEW.message, NEW.selected_records) IS DISTINCT FROM (OLD.recipient_user_id, OLD.issue_kind, OLD.message, OLD.selected_records) THEN RAISE EXCEPTION 'approved support request is immutable'; END IF;
      ELSIF TG_TABLE_NAME = 'challenge_support_accesses' THEN
        IF NOT EXISTS (SELECT 1 FROM challenge_support_tickets t WHERE t.id = NEW.challenge_support_ticket_id AND t.savings_enrollment_id = NEW.savings_enrollment_id AND t.recipient_user_id = NEW.recipient_user_id) THEN RAISE EXCEPTION 'support ticket scope mismatch'; END IF;
        IF TG_OP = 'UPDATE' THEN
          IF (NEW.challenge_support_ticket_id, NEW.recipient_user_id, NEW.selected_records, NEW.reason, NEW.expires_at) IS DISTINCT FROM (OLD.challenge_support_ticket_id, OLD.recipient_user_id, OLD.selected_records, OLD.reason, OLD.expires_at) THEN RAISE EXCEPTION 'approved support scope is immutable'; END IF;
          IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN RAISE EXCEPTION 'support access cannot be revived'; END IF;
        END IF;
      ELSIF TG_TABLE_NAME = 'financial_source_uses' AND TG_OP = 'UPDATE' THEN
        IF NEW.financial_document_import_id IS DISTINCT FROM OLD.financial_document_import_id AND NEW.financial_document_import_id IS NOT NULL THEN RAISE EXCEPTION 'source use identity is immutable'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_privacy_events_scope BEFORE INSERT OR UPDATE ON public.challenge_privacy_events FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_privacy_grants_scope BEFORE INSERT OR UPDATE ON public.challenge_privacy_grants FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_privacy_reads_scope BEFORE INSERT OR UPDATE ON public.challenge_privacy_reads FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_reminder_events_scope BEFORE INSERT OR UPDATE ON public.challenge_reminder_events FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_reminder_preferences_scope BEFORE INSERT OR UPDATE ON public.challenge_reminder_preferences FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_reminders_scope BEFORE INSERT OR UPDATE ON public.challenge_reminders FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_support_accesses_scope BEFORE INSERT OR UPDATE ON public.challenge_support_accesses FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER challenge_support_tickets_scope BEFORE INSERT OR UPDATE ON public.challenge_support_tickets FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~SQL
    CREATE TRIGGER financial_source_uses_scope BEFORE INSERT OR UPDATE ON public.financial_source_uses FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard();
  SQL
  execute <<~'SQL'
    CREATE OR REPLACE FUNCTION public.challenge_chat_scope_guard()
     RETURNS trigger
     LANGUAGE plpgsql
    AS $function$
    DECLARE session_cohort bigint;
    BEGIN
      IF TG_TABLE_NAME = 'chat_sessions' THEN
        IF NEW.household_id IS DISTINCT FROM OLD.household_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
          OR NEW.cohort_id IS DISTINCT FROM OLD.cohort_id THEN
          RAISE EXCEPTION 'conversation actor and program are immutable';
        END IF;
      ELSE
        IF TG_OP = 'UPDATE' AND NEW.chat_session_id IS DISTINCT FROM OLD.chat_session_id THEN
          RAISE EXCEPTION 'message conversation is immutable';
        END IF;
        SELECT cohort_id INTO session_cohort FROM chat_sessions WHERE id = NEW.chat_session_id;
        IF TG_OP = 'UPDATE' AND session_cohort IS NOT NULL AND (
          NEW.cohort_id IS DISTINCT FROM OLD.cohort_id OR NEW.cohort_release_id IS DISTINCT FROM OLD.cohort_release_id
        ) THEN RAISE EXCEPTION 'challenge message release attribution is immutable'; END IF;
        IF session_cohort IS NOT NULL AND (NEW.cohort_id IS DISTINCT FROM session_cohort OR NOT EXISTS (
          SELECT 1 FROM cohort_releases r WHERE r.id = NEW.cohort_release_id AND r.cohort_id = session_cohort
            AND r.tool_registry_version >= 3 AND r.experience_snapshot->'config'->>'experience_mode' = 'savings_challenge'
        )) THEN RAISE EXCEPTION 'message must match its sealed challenge conversation'; END IF;
      END IF;
      RETURN NEW;
    END; $function$
  SQL
  execute <<~'SQL'
    CREATE TRIGGER chat_messages_scope BEFORE INSERT OR UPDATE ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION challenge_chat_scope_guard();
  SQL
  execute <<~'SQL'
    CREATE TRIGGER chat_sessions_scope BEFORE UPDATE ON public.chat_sessions FOR EACH ROW EXECUTE FUNCTION challenge_chat_scope_guard();
  SQL
end
