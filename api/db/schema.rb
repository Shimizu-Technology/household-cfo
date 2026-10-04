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

ActiveRecord::Schema[8.1].define(version: 2026_10_04_160000) do
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
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.bigint "plaid_account_id"
    t.datetime "plaid_reconciled_at"
    t.jsonb "source_metadata", default: {}, null: false
    t.string "source_type", default: "manual_ui", null: false
    t.datetime "updated_at", null: false
    t.index "household_id, account_type, lower((label)::text)", name: "index_active_accounts_on_household_type_label", unique: true, where: "(active = true)"
    t.index ["household_id", "account_type"], name: "index_accounts_on_household_id_and_account_type"
    t.index ["household_id", "active"], name: "index_accounts_on_household_id_and_active"
    t.index ["household_id"], name: "index_accounts_on_household_id"
    t.index ["plaid_account_id"], name: "index_accounts_on_unique_plaid_account", unique: true, where: "(plaid_account_id IS NOT NULL)"
    t.check_constraint "(account_type::text = ANY (ARRAY['checking'::character varying::text, 'savings'::character varying::text])) OR balance_cents >= 0", name: "accounts_balance_signed_only_for_cash"
    t.check_constraint "active = true AND archived_at IS NULL OR active = false AND archived_at IS NOT NULL", name: "accounts_archive_state_valid"
    t.check_constraint "balance_known = true OR balance_cents = 0 AND balance_as_of_on IS NULL", name: "accounts_unknown_balance_zero_without_date"
    t.check_constraint "jsonb_typeof(source_metadata) = 'object'::text", name: "accounts_source_metadata_object"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_ui'::character varying::text, 'mia'::character varying::text, 'document_import'::character varying::text, 'setup'::character varying::text, 'plaid'::character varying::text])", name: "accounts_source_type_valid"
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
    t.check_constraint "source::text = ANY (ARRAY['manual'::character varying::text, 'setup'::character varying::text, 'imported'::character varying::text, 'mia_suggested'::character varying::text])", name: "budget_allocations_source_valid"
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
    t.check_constraint "stack_key::text = ANY (ARRAY['non_discretionary'::character varying::text, 'discretionary'::character varying::text, 'sinking_expected'::character varying::text, 'sinking_unexpected'::character varying::text])", name: "budget_categories_stack_key_valid"
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
    t.check_constraint "status::text = ANY (ARRAY['open'::character varying::text, 'reviewing'::character varying::text, 'closed'::character varying::text])", name: "budget_periods_status_valid"
  end

  create_table "budget_years", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["household_id", "year"], name: "index_budget_years_on_household_id_and_year", unique: true
    t.index ["household_id"], name: "index_budget_years_on_household_id"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'active'::character varying::text, 'archived'::character varying::text])", name: "budget_years_status_valid"
    t.check_constraint "year >= 2000 AND year <= 2100", name: "budget_years_year_reasonable"
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
    t.jsonb "presentation", default: {}, null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "created_at"], name: "index_chat_messages_on_chat_session_id_and_created_at"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["coach_persona_version_id"], name: "index_chat_messages_on_coach_persona_version_id"
    t.index ["cohort_id"], name: "index_chat_messages_on_cohort_id"
    t.index ["cohort_release_id", "cohort_id"], name: "idx_chat_messages_release_cohort"
    t.index ["cohort_release_id"], name: "index_chat_messages_on_cohort_release_id"
    t.index ["role"], name: "index_chat_messages_on_role"
    t.check_constraint "(assistant_author IS NULL OR role::text = 'assistant'::text) AND (coach_persona_version_id IS NULL OR role::text = 'assistant'::text AND assistant_author IS NOT NULL)", name: "chat_messages_persona_attribution_complete"
    t.check_constraint "(role::text = ANY (ARRAY['user'::character varying::text, 'assistant'::character varying::text])) AND char_length(content) <= 8000", name: "chat_messages_content_length_by_role"
    t.check_constraint "assistant_author IS NULL OR char_length(assistant_author::text) >= 1 AND char_length(assistant_author::text) <= 80", name: "chat_messages_assistant_author_length"
    t.check_constraint "cohort_release_id IS NULL OR cohort_id IS NOT NULL", name: "chat_messages_release_attribution_complete"
    t.check_constraint "jsonb_typeof(presentation) = 'object'::text", name: "chat_messages_presentation_object"
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
    t.check_constraint "source_ingestion_method::text = ANY (ARRAY['upload'::character varying::text, 'url_snapshot'::character varying::text])", name: "coach_content_item_draft_provenances_ingestion_method_valid"
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
    t.check_constraint "source_ingestion_method::text = ANY (ARRAY['upload'::character varying::text, 'url_snapshot'::character varying::text])", name: "coach_content_item_version_provenances_ingestion_method_valid"
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
    t.check_constraint "kind::text = ANY (ARRAY['guidance'::character varying::text, 'script'::character varying::text, 'example'::character varying::text, 'phrase'::character varying::text, 'culture'::character varying::text, 'finance_reference'::character varying::text])", name: "coach_content_items_kind_valid"
    t.check_constraint "octet_length(draft_content) <= 12000", name: "coach_content_items_content_bytes"
    t.check_constraint "scope::text = 'platform'::text AND coach_workspace_id IS NULL OR scope::text = 'coach'::text AND coach_workspace_id IS NOT NULL", name: "coach_content_items_workspace_matches_scope"
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying::text, 'platform'::character varying::text])", name: "coach_content_items_scope_valid"
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
    t.check_constraint "pack_kind::text = ANY (ARRAY['voice_culture'::character varying::text, 'coaching_method'::character varying::text, 'finance_reference'::character varying::text])", name: "coach_content_packs_kind_valid"
    t.check_constraint "scope::text = 'platform'::text AND coach_workspace_id IS NULL OR scope::text = 'coach'::text AND coach_workspace_id IS NOT NULL", name: "coach_content_packs_workspace_matches_scope"
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying::text, 'platform'::character varying::text])", name: "coach_content_packs_scope_valid"
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
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying::text, 'succeeded'::character varying::text, 'failed'::character varying::text, 'superseded'::character varying::text])", name: "coach_content_source_attempt_status_valid"
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
    t.check_constraint "status::text = ANY (ARRAY['proposed'::character varying::text, 'accepted'::character varying::text, 'rejected'::character varying::text, 'superseded'::character varying::text])", name: "coach_content_source_candidates_status_valid"
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
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying::text, 'platform'::character varying::text])", name: "url_intakes_scope_valid"
    t.check_constraint "status::text = 'deleted'::text OR redaction_requested_at IS NOT NULL OR encrypted_url_ciphertext IS NOT NULL AND encrypted_url_iv IS NOT NULL AND encrypted_url_auth_tag IS NOT NULL", name: "url_intakes_encrypted_payload_present"
    t.check_constraint "status::text = 'registered'::text AND coach_content_source_id IS NOT NULL OR status::text = 'deleted'::text OR (status::text <> ALL (ARRAY['registered'::character varying::text, 'deleted'::character varying::text])) AND coach_content_source_id IS NULL", name: "url_intakes_source_state_coherent"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying::text, 'fetching'::character varying::text, 'staged'::character varying::text, 'registering'::character varying::text, 'registered'::character varying::text, 'failed'::character varying::text, 'cleanup_pending'::character varying::text, 'cleanup_failed'::character varying::text, 'deleted'::character varying::text])", name: "url_intakes_status_valid"
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
    t.check_constraint "ingestion_method::text = ANY (ARRAY['upload'::character varying::text, 'url_snapshot'::character varying::text])", name: "coach_content_sources_ingestion_method_valid"
    t.check_constraint "scope::text = 'platform'::text AND coach_workspace_id IS NULL OR scope::text = 'coach'::text AND coach_workspace_id IS NOT NULL", name: "coach_content_sources_workspace_matches_scope"
    t.check_constraint "scope::text = ANY (ARRAY['coach'::character varying::text, 'platform'::character varying::text])", name: "coach_content_sources_scope_valid"
    t.check_constraint "status::text = ANY (ARRAY['uploading'::character varying::text, 'verifying'::character varying::text, 'upload_cleanup'::character varying::text, 'queued'::character varying::text, 'processing'::character varying::text, 'needs_review'::character varying::text, 'failed'::character varying::text, 'deletion_pending'::character varying::text, 'deletion_failed'::character varying::text, 'source_deleted'::character varying::text, 'upload_cleanup_failed'::character varying::text])", name: "coach_content_sources_status_valid"
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
    t.check_constraint "(operation_key::text = ANY (ARRAY['cohort.release.seal'::character varying::text, 'cohort.release.restore'::character varying::text])) AND cohort_release_id IS NOT NULL AND cohort_rollout_transition_id IS NULL OR (operation_key::text = ANY (ARRAY['cohort.rollout.plan'::character varying::text, 'cohort.rollout.advance'::character varying::text, 'cohort.rollout.pause'::character varying::text, 'cohort.rollout.resume'::character varying::text, 'cohort.rollout.cancel'::character varying::text, 'cohort.rollout.rollback'::character varying::text])) AND cohort_release_id IS NULL AND cohort_rollout_transition_id IS NOT NULL", name: "coach_operations_result_matches_key"
    t.check_constraint "actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying::text, 'owner'::character varying::text, 'reviewer'::character varying::text])", name: "coach_operations_actor_role_valid"
    t.check_constraint "char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100", name: "coach_operations_request_key_bounded"
    t.check_constraint "invocation_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND request_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND normalized_input_digest::text ~ '^[0-9a-f]{64}$'::text AND before_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND predicted_after_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND after_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_operations_digest_shape"
    t.check_constraint "jsonb_typeof(normalized_input) = 'object'::text AND jsonb_typeof(before_snapshot) = 'object'::text AND jsonb_typeof(predicted_after_snapshot) = 'object'::text AND jsonb_typeof(after_snapshot) = 'object'::text", name: "coach_operations_json_shape"
    t.check_constraint "num_nonnulls(cohort_release_id, cohort_rollout_transition_id) = 1", name: "coach_operations_exactly_one_result"
    t.check_constraint "octet_length(normalized_input::text) <= 16384 AND octet_length(before_snapshot::text) <= 16384 AND octet_length(predicted_after_snapshot::text) <= 16384 AND octet_length(after_snapshot::text) <= 16384", name: "coach_operations_json_bounded"
    t.check_constraint "operation_key::text = ANY (ARRAY['cohort.release.seal'::character varying::text, 'cohort.release.restore'::character varying::text, 'cohort.rollout.plan'::character varying::text, 'cohort.rollout.advance'::character varying::text, 'cohort.rollout.pause'::character varying::text, 'cohort.rollout.resume'::character varying::text, 'cohort.rollout.cancel'::character varying::text, 'cohort.rollout.rollback'::character varying::text])", name: "coach_operations_key_valid"
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
    t.check_constraint "decision::text = ANY (ARRAY['approved'::character varying::text, 'rejected'::character varying::text])", name: "persona_evaluation_approvals_decision_valid"
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
    t.check_constraint "case_kind::text = ANY (ARRAY['system'::character varying::text, 'custom'::character varying::text])", name: "persona_evaluation_cases_kind_valid"
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
    t.check_constraint "status::text = ANY (ARRAY['passed'::character varying::text, 'failed'::character varying::text, 'error'::character varying::text])", name: "persona_evaluation_results_status_valid"
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
    t.check_constraint "cases_digest::text ~ '^[0-9a-f]{64}$'::text AND request_fingerprint::text ~ '^[0-9a-f]{64}$'::text AND char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100 AND execution_attempts >= 0 AND (run_digest IS NULL OR run_digest::text ~ '^[0-9a-f]{64}$'::text) AND (status::text = 'pending'::text AND started_at IS NULL AND completed_at IS NULL AND run_digest IS NULL OR status::text = 'running'::text AND started_at IS NOT NULL AND completed_at IS NULL AND run_digest IS NULL OR (status::text = ANY (ARRAY['passed'::character varying::text, 'failed'::character varying::text, 'error'::character varying::text])) AND started_at IS NOT NULL AND completed_at IS NOT NULL AND run_digest IS NOT NULL)", name: "persona_evaluation_runs_lifecycle"
    t.check_constraint "lease_token IS NULL AND lease_expires_at IS NULL AND heartbeat_at IS NULL AND lease_claimed_at IS NULL OR lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND heartbeat_at IS NOT NULL", name: "persona_evaluation_runs_lease_complete"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'passed'::character varying::text, 'failed'::character varying::text, 'error'::character varying::text])", name: "persona_evaluation_runs_status_valid"
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
    t.check_constraint "event_type::text = ANY (ARRAY['publish'::character varying::text, 'rollback'::character varying::text])", name: "coach_persona_publication_events_type_valid"
    t.check_constraint "jsonb_typeof(phrase_audience_attestation_digests) = 'array'::text", name: "persona_publication_events_audience_attestation_digests_array"
    t.check_constraint "release_gate_version::text = 'gate_v1'::text AND release_evidence_digest IS NULL OR release_gate_version::text = 'gate_v2'::text AND release_evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_publication_events_release_evidence_complete"
    t.check_constraint "release_gate_version::text = ANY (ARRAY['gate_v1'::character varying::text, 'gate_v2'::character varying::text])", name: "persona_publication_events_release_gate_valid"
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
    t.check_constraint "(status::text = ANY (ARRAY['pending'::character varying::text, 'superseded'::character varying::text, 'stale'::character varying::text])) OR resolution_idempotency_key IS NOT NULL", name: "persona_setup_proposals_user_resolution_key_present"
    t.check_constraint "base_config_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_setup_proposals_base_digest_sha256"
    t.check_constraint "base_draft_revision > 0", name: "persona_setup_proposals_revision_positive"
    t.check_constraint "jsonb_typeof(before_state) = 'object'::text AND jsonb_typeof(after_state) = 'object'::text", name: "persona_setup_proposals_states_objects"
    t.check_constraint "jsonb_typeof(operations) = 'array'::text AND jsonb_array_length(operations) <= 24", name: "persona_setup_proposals_operations_array"
    t.check_constraint "octet_length(operations::text) <= 32768 AND octet_length(before_state::text) <= 65536 AND octet_length(after_state::text) <= 65536", name: "persona_setup_proposals_payload_sizes"
    t.check_constraint "proposal_digest::text ~ '^[0-9a-f]{64}$'::text", name: "persona_setup_proposals_digest_sha256"
    t.check_constraint "status::text = 'pending'::text AND resolved_by_user_id IS NULL AND resolved_at IS NULL OR status::text <> 'pending'::text AND resolved_by_user_id IS NOT NULL AND resolved_at IS NOT NULL", name: "persona_setup_proposals_resolution_complete"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'applied'::character varying::text, 'rejected'::character varying::text, 'superseded'::character varying::text, 'stale'::character varying::text])", name: "persona_setup_proposals_status_valid"
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
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'completed'::character varying::text, 'abandoned'::character varying::text])", name: "persona_setup_sessions_status_valid"
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
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying::text, 'ready'::character varying::text, 'failed'::character varying::text, 'stale'::character varying::text])", name: "persona_setup_turns_status_valid"
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
    t.check_constraint "release_gate_version::text = 'gate_v1'::text AND release_evidence_schema IS NULL AND coach_persona_behavioral_preview_evidence_id IS NULL AND behavioral_preview_digest IS NULL OR release_gate_version::text = 'gate_v2'::text AND (release_evidence_schema::text = ANY (ARRAY['persona_release_evidence_v2'::character varying::text, 'persona_release_evidence_v3'::character varying::text])) AND (release_evidence_schema::text = 'persona_release_evidence_v2'::text AND coach_persona_behavioral_preview_evidence_id IS NULL AND behavioral_preview_digest IS NULL OR release_evidence_schema::text = 'persona_release_evidence_v3'::text AND coach_persona_behavioral_preview_evidence_id IS NOT NULL AND behavioral_preview_digest::text ~ '^[0-9a-f]{64}$'::text)", name: "persona_versions_behavioral_preview_shape"
    t.check_constraint "release_gate_version::text = ANY (ARRAY['gate_v1'::character varying::text, 'gate_v2'::character varying::text])", name: "persona_versions_release_gate_valid"
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
    t.check_constraint "release_gate_version::text = ANY (ARRAY['gate_v1'::character varying::text, 'gate_v2'::character varying::text])", name: "coach_personas_release_gate_valid"
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
    t.check_constraint "decision::text = ANY (ARRAY['approved'::character varying::text, 'rejected'::character varying::text])", name: "phrase_attestations_decision_valid"
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
    t.check_constraint "decision::text = ANY (ARRAY['approved'::character varying::text, 'rejected'::character varying::text])", name: "phrase_audience_attestations_decision_valid"
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
    t.check_constraint "status::text = 'draft'::text AND submitted_at IS NULL OR (status::text = ANY (ARRAY['submitted'::character varying::text, 'rejected'::character varying::text])) AND submitted_at IS NOT NULL OR status::text = 'superseded'::text", name: "phrase_proposals_submission_coherent"
    t.check_constraint "status::text = 'superseded'::text AND superseded_at IS NOT NULL OR status::text <> 'superseded'::text AND superseded_at IS NULL", name: "phrase_proposals_supersession_coherent"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'submitted'::character varying::text, 'rejected'::character varying::text, 'superseded'::character varying::text])", name: "phrase_proposals_status_valid"
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
    t.check_constraint "event_type::text = ANY (ARRAY['created'::character varying::text, 'verification_requested'::character varying::text, 'verified'::character varying::text, 'activated'::character varying::text, 'disabled'::character varying::text])", name: "coach_workspace_domain_events_type"
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
    t.check_constraint "(status::text <> ALL (ARRAY['verified'::character varying::text, 'active'::character varying::text])) OR verified_at IS NOT NULL", name: "coach_workspace_domains_verified_evidence"
    t.check_constraint "(status::text = 'disabled'::text) = (disabled_at IS NOT NULL)", name: "coach_workspace_domains_disabled_evidence"
    t.check_constraint "NOT is_primary OR status::text = 'active'::text", name: "coach_workspace_domains_primary_active"
    t.check_constraint "char_length(hostname::text) >= 4 AND char_length(hostname::text) <= 253", name: "coach_workspace_domains_hostname_length"
    t.check_constraint "hostname::text = lower(hostname::text) AND hostname::text ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$'::text", name: "coach_workspace_domains_hostname"
    t.check_constraint "kind::text = ANY (ARRAY['managed_subdomain'::character varying::text, 'custom'::character varying::text])", name: "coach_workspace_domains_kind"
    t.check_constraint "status::text <> 'active'::text OR activated_at IS NOT NULL", name: "coach_workspace_domains_active_evidence"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'active'::character varying::text, 'disabled'::character varying::text])", name: "coach_workspace_domains_status"
    t.check_constraint "verification_token_digest IS NULL OR verification_token_digest::text ~ '^[0-9a-f]{64}$'::text", name: "coach_workspace_domains_token_digest"
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
    t.check_constraint "role::text = ANY (ARRAY['owner'::character varying::text, 'editor'::character varying::text, 'reviewer'::character varying::text, 'viewer'::character varying::text])", name: "coach_workspace_memberships_role_valid"
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
    t.check_constraint "event_type::text = ANY (ARRAY['publish'::character varying::text, 'rollback'::character varying::text])", name: "cohort_experience_publication_events_type"
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
    t.check_constraint "role::text = ANY (ARRAY['participant'::character varying::text, 'coach'::character varying::text, 'admin'::character varying::text])", name: "cohort_memberships_role_valid"
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
    t.check_constraint "event_type::text = 'backfill'::text AND cohort_rollout_id IS NULL AND cohort_rollout_transition_id IS NULL AND actor_user_id IS NULL AND actor_role_snapshot IS NULL OR event_type::text = 'rollout_completed'::text AND cohort_rollout_id IS NOT NULL AND cohort_rollout_transition_id IS NOT NULL AND actor_user_id IS NOT NULL AND (actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying::text, 'owner'::character varying::text, 'reviewer'::character varying::text]))", name: "release_activation_events_shape"
    t.check_constraint "event_type::text = ANY (ARRAY['backfill'::character varying::text, 'rollout_completed'::character varying::text])", name: "release_activation_events_type_valid"
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
    t.check_constraint "event_type::text = ANY (ARRAY['wave'::character varying::text, 'rollback'::character varying::text])", name: "cohort_release_exposures_type_valid"
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
    t.check_constraint "(experience_mode::text = ANY (ARRAY['published_version'::character varying::text, 'safe_default'::character varying::text])) AND (experience_mode::text = 'published_version'::text AND cohort_experience_version_id IS NOT NULL OR experience_mode::text = 'safe_default'::text AND cohort_experience_version_id IS NULL)", name: "cohort_releases_experience_shape"
    t.check_constraint "(persona_mode::text = ANY (ARRAY['published_version'::character varying::text, 'neutral_builtin'::character varying::text])) AND (persona_mode::text = 'published_version'::text AND coach_persona_id IS NOT NULL AND coach_persona_version_id IS NOT NULL OR persona_mode::text = 'neutral_builtin'::text AND coach_persona_id IS NULL AND coach_persona_version_id IS NULL)", name: "cohort_releases_persona_shape"
    t.check_constraint "brand_snapshot IS NULL OR jsonb_typeof(brand_snapshot) = 'object'::text", name: "cohort_releases_brand_json_shape"
    t.check_constraint "brand_snapshot IS NULL OR octet_length(brand_snapshot::text) <= 32768", name: "cohort_releases_brand_json_bounded"
    t.check_constraint "brand_snapshot_digest IS NULL OR brand_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text", name: "cohort_releases_brand_digest_shape"
    t.check_constraint "char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100", name: "cohort_releases_request_key_bounded"
    t.check_constraint "event_type::text = 'restore'::text AND source_release_id IS NOT NULL OR (event_type::text = ANY (ARRAY['release'::character varying::text, 'reconciliation'::character varying::text])) AND source_release_id IS NULL", name: "cohort_releases_source_shape"
    t.check_constraint "event_type::text = ANY (ARRAY['release'::character varying::text, 'restore'::character varying::text, 'reconciliation'::character varying::text])", name: "cohort_releases_event_type_valid"
    t.check_constraint "jsonb_typeof(persona_snapshot) = 'object'::text AND jsonb_typeof(experience_snapshot) = 'object'::text AND jsonb_typeof(tool_registry_snapshot) = 'object'::text AND jsonb_typeof(bundle) = 'object'::text AND jsonb_typeof(manifest) = 'object'::text", name: "cohort_releases_json_shape"
    t.check_constraint "manifest_schema::text = 'cohort_release_manifest_v1'::text AND brand_mode IS NULL AND workspace_brand_version_id IS NULL AND brand_snapshot IS NULL AND brand_snapshot_digest IS NULL OR manifest_schema::text = 'cohort_release_manifest_v2'::text AND brand_snapshot IS NOT NULL AND brand_snapshot_digest IS NOT NULL AND (brand_mode::text = 'published_version'::text AND workspace_brand_version_id IS NOT NULL OR brand_mode::text = 'legacy_household_cfo_builtin'::text AND workspace_brand_version_id IS NULL)", name: "cohort_releases_brand_shape"
    t.check_constraint "manifest_schema::text = ANY (ARRAY['cohort_release_manifest_v1'::character varying, 'cohort_release_manifest_v2'::character varying]::text[])", name: "cohort_releases_manifest_schema_valid"
    t.check_constraint "octet_length(persona_snapshot::text) <= 65536 AND octet_length(experience_snapshot::text) <= 16384 AND octet_length(tool_registry_snapshot::text) <= 65536 AND octet_length(bundle::text) <= 196608 AND octet_length(manifest::text) <= 262144", name: "cohort_releases_json_bounded"
    t.check_constraint "persona_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND experience_snapshot_digest::text ~ '^[0-9a-f]{64}$'::text AND tool_registry_digest::text ~ '^[0-9a-f]{64}$'::text AND bundle_digest::text ~ '^[0-9a-f]{64}$'::text AND manifest_digest::text ~ '^[0-9a-f]{64}$'::text AND request_fingerprint::text ~ '^[0-9a-f]{64}$'::text", name: "cohort_releases_digest_shape"
    t.check_constraint "publication_source::text = 'user'::text AND released_by_user_id IS NOT NULL AND (actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying::text, 'owner'::character varying::text, 'reviewer'::character varying::text])) OR (publication_source::text = ANY (ARRAY['legacy_backfill'::character varying::text, 'system'::character varying::text])) AND released_by_user_id IS NULL AND actor_role_snapshot IS NULL", name: "cohort_releases_actor_shape"
    t.check_constraint "publication_source::text = ANY (ARRAY['user'::character varying::text, 'legacy_backfill'::character varying::text, 'system'::character varying::text])", name: "cohort_releases_publication_source_valid"
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
    t.check_constraint "(event_type::text = ANY (ARRAY['activated'::character varying::text, 'advanced'::character varying::text, 'completed'::character varying::text, 'rolled_back'::character varying::text])) OR participant_runtime_changed = false", name: "cohort_rollout_transitions_runtime_changed_shape"
    t.check_constraint "(event_type::text = ANY (ARRAY['activated'::character varying::text, 'advanced'::character varying::text, 'completed'::character varying::text])) AND readiness_digest::text ~ '^[0-9a-f]{64}$'::text OR (event_type::text <> ALL (ARRAY['activated'::character varying::text, 'advanced'::character varying::text, 'completed'::character varying::text])) AND readiness_digest IS NULL", name: "cohort_rollout_transitions_readiness_evidence"
    t.check_constraint "(from_wave_position IS NULL OR from_wave_position >= 0 AND from_wave_position <= 25) AND (to_wave_position IS NULL OR to_wave_position >= 0 AND to_wave_position <= 25)", name: "cohort_rollout_transitions_wave_positions_bounded"
    t.check_constraint "(to_status::text = ANY (ARRAY['planned'::character varying::text, 'active'::character varying::text, 'paused'::character varying::text, 'completed'::character varying::text, 'cancelled'::character varying::text, 'rolled_back'::character varying::text])) AND (from_status IS NULL OR (from_status::text = ANY (ARRAY['planned'::character varying::text, 'active'::character varying::text, 'paused'::character varying::text, 'completed'::character varying::text, 'cancelled'::character varying::text, 'rolled_back'::character varying::text])))", name: "cohort_rollout_transitions_status_valid"
    t.check_constraint "actor_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying::text, 'owner'::character varying::text, 'reviewer'::character varying::text])", name: "cohort_rollout_transitions_actor_role_valid"
    t.check_constraint "event_type::text = 'planned'::text AND from_status IS NULL AND to_status::text = 'planned'::text AND from_wave_position IS NULL AND to_wave_position = 0 OR event_type::text = 'activated'::text AND from_status::text = 'planned'::text AND to_status::text = 'active'::text AND from_wave_position = 0 AND to_wave_position = 1 OR event_type::text = 'advanced'::text AND from_status::text = 'active'::text AND to_status::text = 'active'::text AND from_wave_position >= 1 AND to_wave_position = (from_wave_position + 1) OR event_type::text = 'completed'::text AND from_status::text = 'active'::text AND to_status::text = 'completed'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position OR event_type::text = 'paused'::text AND from_status::text = 'active'::text AND to_status::text = 'paused'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position OR event_type::text = 'resumed'::text AND from_status::text = 'paused'::text AND to_status::text = 'active'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position OR event_type::text = 'cancelled'::text AND from_status::text = 'planned'::text AND to_status::text = 'cancelled'::text AND from_wave_position = 0 AND to_wave_position = 0 OR event_type::text = 'rolled_back'::text AND (from_status::text = ANY (ARRAY['active'::character varying::text, 'paused'::character varying::text])) AND to_status::text = 'rolled_back'::text AND from_wave_position >= 1 AND to_wave_position = from_wave_position", name: "cohort_rollout_transitions_event_shape"
    t.check_constraint "event_type::text = 'rolled_back'::text AND rollback_cohort_release_id IS NOT NULL OR event_type::text <> 'rolled_back'::text AND rollback_cohort_release_id IS NULL", name: "cohort_rollout_transitions_rollback_shape"
    t.check_constraint "event_type::text = ANY (ARRAY['planned'::character varying::text, 'activated'::character varying::text, 'advanced'::character varying::text, 'paused'::character varying::text, 'resumed'::character varying::text, 'completed'::character varying::text, 'cancelled'::character varying::text, 'rolled_back'::character varying::text])", name: "cohort_rollout_transitions_event_valid"
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
    t.check_constraint "planned_by_role_snapshot::text = ANY (ARRAY['platform_admin'::character varying::text, 'owner'::character varying::text, 'reviewer'::character varying::text])", name: "cohort_rollouts_actor_role_valid"
    t.check_constraint "status::text = 'planned'::text AND activated_at IS NULL AND paused_at IS NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'active'::text AND activated_at IS NOT NULL AND paused_at IS NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'paused'::text AND activated_at IS NOT NULL AND paused_at IS NOT NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'completed'::text AND activated_at IS NOT NULL AND paused_at IS NULL AND completed_at IS NOT NULL AND cancelled_at IS NULL AND rolled_back_at IS NULL OR status::text = 'cancelled'::text AND activated_at IS NULL AND paused_at IS NULL AND completed_at IS NULL AND cancelled_at IS NOT NULL AND rolled_back_at IS NULL OR status::text = 'rolled_back'::text AND activated_at IS NOT NULL AND completed_at IS NULL AND cancelled_at IS NULL AND rolled_back_at IS NOT NULL", name: "cohort_rollouts_lifecycle_timestamps"
    t.check_constraint "status::text = 'rolled_back'::text AND rollback_cohort_release_id IS NOT NULL AND rolled_back_at IS NOT NULL OR status::text <> 'rolled_back'::text AND rollback_cohort_release_id IS NULL AND rolled_back_at IS NULL", name: "cohort_rollouts_rollback_shape"
    t.check_constraint "status::text = ANY (ARRAY['planned'::character varying::text, 'active'::character varying::text, 'paused'::character varying::text, 'completed'::character varying::text, 'cancelled'::character varying::text, 'rolled_back'::character varying::text])", name: "cohort_rollouts_status_valid"
  end

  create_table "cohorts", force: :cascade do |t|
    t.bigint "active_cohort_release_id"
    t.bigint "coach_workspace_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.date "ends_on"
    t.string "name", null: false
    t.text "notes"
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
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'enrolling'::character varying::text, 'active'::character varying::text, 'completed'::character varying::text, 'archived'::character varying::text])", name: "cohorts_status_valid"
  end

  create_table "debts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.bigint "balance_cents", default: 0, null: false
    t.boolean "balance_known", default: true, null: false
    t.datetime "created_at", null: false
    t.string "debt_type", default: "other", null: false
    t.bigint "household_id", null: false
    t.decimal "interest_rate_percent", precision: 6, scale: 2
    t.string "label", null: false
    t.bigint "minimum_payment_cents", default: 0, null: false
    t.boolean "minimum_payment_known", default: true, null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.string "source_type", default: "manual_ui", null: false
    t.datetime "updated_at", null: false
    t.index "household_id, debt_type, lower((label)::text)", name: "index_active_debts_on_household_type_label", unique: true, where: "(active = true)"
    t.index ["household_id", "active"], name: "index_debts_on_household_id_and_active"
    t.index ["household_id", "debt_type"], name: "index_debts_on_household_id_and_debt_type"
    t.index ["household_id"], name: "index_debts_on_household_id"
    t.check_constraint "active = true AND archived_at IS NULL OR active = false AND archived_at IS NOT NULL", name: "debts_archive_state_valid"
    t.check_constraint "balance_cents >= 0", name: "debts_balance_cents_non_negative"
    t.check_constraint "minimum_payment_cents >= 0", name: "debts_minimum_payment_cents_non_negative"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_ui'::character varying::text, 'mia'::character varying::text, 'document_import'::character varying::text, 'setup'::character varying::text])", name: "debts_source_type_valid"
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
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying::text, 'succeeded'::character varying::text, 'failed'::character varying::text])", name: "financial_document_import_attempts_status_valid"
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
    t.check_constraint "balance_cents IS NULL OR balance_cents >= 0 OR target_type::text = 'account'::text AND (account_type::text = ANY (ARRAY['checking'::character varying::text, 'savings'::character varying::text]))", name: "financial_doc_items_balance_cents_valid"
    t.check_constraint "confidence IS NULL OR (confidence::text = ANY (ARRAY['high'::character varying::text, 'medium'::character varying::text, 'low'::character varying::text]))", name: "financial_document_import_items_confidence_valid"
    t.check_constraint "interest_rate_percent IS NULL OR interest_rate_percent >= 0::numeric AND interest_rate_percent <= 999.99", name: "financial_doc_items_apr_valid"
    t.check_constraint "payment_cents IS NULL OR payment_cents >= 0", name: "financial_doc_items_payment_cents_non_negative"
    t.check_constraint "target_type::text = ANY (ARRAY['income_source'::character varying::text, 'expense_item'::character varying::text, 'account'::character varying::text, 'debt'::character varying::text, 'goal'::character varying::text, 'profile_note'::character varying::text])", name: "financial_document_import_items_target_type_valid"
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
    t.index ["s3_key"], name: "index_financial_document_imports_on_s3_key", unique: true, where: "(s3_key IS NOT NULL)"
    t.index ["source_deleted_by_user_id"], name: "index_financial_document_imports_on_source_deleted_by_user_id"
    t.index ["uploaded_by_user_id"], name: "index_financial_document_imports_on_uploaded_by_user_id"
    t.check_constraint "byte_size >= 0", name: "financial_document_imports_byte_size_non_negative"
    t.check_constraint "document_kind::text = ANY (ARRAY['spreadsheet'::character varying::text, 'statement'::character varying::text, 'pay_stub'::character varying::text, 'receipt'::character varying::text, 'other'::character varying::text])", name: "financial_document_imports_document_kind_valid"
    t.check_constraint "status::text = ANY (ARRAY['uploaded'::character varying::text, 'processing'::character varying::text, 'needs_review'::character varying::text, 'applied'::character varying::text, 'partially_applied'::character varying::text, 'failed'::character varying::text, 'source_deleted'::character varying::text])", name: "financial_document_imports_status_valid"
  end

  create_table "goals", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.integer "current_amount_cents", default: 0, null: false
    t.boolean "current_amount_known", default: false, null: false
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
    t.index ["household_id", "goal_type"], name: "index_goals_on_household_id_and_goal_type"
    t.index ["household_id", "priority"], name: "index_goals_on_household_id_and_priority"
    t.index ["household_id", "record_kind", "priority"], name: "index_goals_on_kind_and_priority"
    t.index ["household_id"], name: "index_goals_on_household_id"
    t.index ["household_id"], name: "index_goals_on_one_runway_per_household", unique: true, where: "((goal_type)::text = 'runway'::text)"
    t.index ["household_id"], name: "index_goals_on_one_transition_per_household", unique: true, where: "((goal_type)::text = 'transition'::text)"
    t.check_constraint "active = true AND archived_at IS NULL OR active = false AND archived_at IS NOT NULL", name: "goals_archive_state_valid"
    t.check_constraint "current_amount_cents >= 0", name: "goals_current_amount_cents_non_negative"
    t.check_constraint "current_amount_known = true OR current_amount_cents = 0", name: "goals_unknown_current_is_zero"
    t.check_constraint "jsonb_typeof(source_metadata) = 'object'::text", name: "goals_source_metadata_object"
    t.check_constraint "record_kind::text = ANY (ARRAY['tracked'::character varying::text, 'policy'::character varying::text])", name: "goals_record_kind_valid"
    t.check_constraint "source_type::text = ANY (ARRAY['manual_ui'::character varying::text, 'mia'::character varying::text, 'document_import'::character varying::text, 'setup'::character varying::text])", name: "goals_source_type_valid"
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
    t.check_constraint "actor_type::text = ANY (ARRAY['user'::character varying::text, 'mia'::character varying::text, 'system'::character varying::text])", name: "household_audit_events_actor_type_valid"
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
    t.check_constraint "category::text = ANY (ARRAY['goal'::character varying::text, 'preference'::character varying::text, 'constraint'::character varying::text, 'habit'::character varying::text, 'coaching_style'::character varying::text, 'follow_up'::character varying::text])", name: "household_memories_category_valid"
    t.check_constraint "char_length(display_value::text) >= 1 AND char_length(display_value::text) <= 500", name: "household_memories_display_value_length"
    t.check_constraint "request_key IS NULL OR char_length(request_key::text) <= 120", name: "household_memories_request_key_length"
    t.check_constraint "sensitivity::text = ANY (ARRAY['ordinary'::character varying::text, 'sensitive'::character varying::text])", name: "household_memories_sensitivity_valid"
    t.check_constraint "source_kind::text = ANY (ARRAY['manual_profile'::character varying::text, 'mia_command'::character varying::text])", name: "household_memories_source_kind_valid"
    t.check_constraint "status::text = ANY (ARRAY['pending_confirmation'::character varying::text, 'user_confirmed'::character varying::text, 'rejected'::character varying::text, 'expired'::character varying::text])", name: "household_memories_status_valid"
    t.check_constraint "visibility::text = 'private'::text", name: "household_memories_visibility_valid"
  end

  create_table "household_operation_executions", force: :cascade do |t|
    t.jsonb "after_snapshot", default: {}, null: false
    t.jsonb "before_snapshot", default: {}, null: false
    t.datetime "completed_at", null: false
    t.datetime "created_at", null: false
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
    t.check_constraint "source::text = ANY (ARRAY['manual'::character varying::text, 'mia'::character varying::text])", name: "household_operations_source_valid"
    t.check_constraint "status::text = 'completed'::text", name: "household_operations_status_valid"
  end

  create_table "household_profiles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "debt_summary_balance_cents", default: 0, null: false
    t.boolean "debt_summary_balance_known", default: false, null: false
    t.bigint "debt_summary_minimum_payment_cents", default: 0, null: false
    t.boolean "debt_summary_minimum_payment_known", default: false, null: false
    t.string "debt_tracking_mode", default: "individual", null: false
    t.bigint "household_id", null: false
    t.string "household_stage"
    t.integer "money_stress_level"
    t.text "notes"
    t.text "primary_decision"
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_household_profiles_on_household_id", unique: true
    t.check_constraint "debt_summary_balance_cents >= 0", name: "household_profiles_debt_summary_balance_non_negative"
    t.check_constraint "debt_summary_minimum_payment_cents >= 0", name: "household_profiles_debt_summary_minimum_non_negative"
    t.check_constraint "debt_tracking_mode::text = ANY (ARRAY['summary'::character varying::text, 'individual'::character varying::text])", name: "household_profiles_debt_tracking_mode_valid"
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
    t.check_constraint "source_type::text = ANY (ARRAY['manual_chat'::character varying::text, 'manual_ui'::character varying::text, 'receipt'::character varying::text, 'screenshot'::character varying::text, 'statement'::character varying::text, 'import'::character varying::text, 'plaid'::character varying::text])", name: "household_transactions_source_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['confirmed'::character varying::text, 'reconciled'::character varying::text, 'ignored'::character varying::text])", name: "household_transactions_status_valid"
    t.check_constraint "total_amount_cents > 0", name: "household_transactions_amount_positive"
  end

  create_table "households", force: :cascade do |t|
    t.jsonb "confirmed_setup_fields", default: [], null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
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
    t.check_constraint "entry_type::text = ANY (ARRAY['recurring_change'::character varying::text, 'one_time'::character varying::text])", name: "income_schedule_entries_type_valid"
    t.check_constraint "retained_after_transition IS NOT TRUE OR entry_type::text = 'recurring_change'::text AND amount_cents > 0", name: "income_schedule_entries_retained_income_valid"
  end

  create_table "income_sources", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "amount_cents", default: 0, null: false
    t.string "cadence", default: "monthly", null: false
    t.datetime "created_at", null: false
    t.date "ends_on"
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.string "source_type", default: "other", null: false
    t.date "starts_on"
    t.datetime "updated_at", null: false
    t.index "household_id, source_type, lower((label)::text)", name: "index_income_sources_on_household_type_lower_label", unique: true, where: "(active = true)"
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
    t.check_constraint "status::text = ANY (ARRAY['not_sent'::character varying::text, 'skipped'::character varying::text, 'sent'::character varying::text, 'failed'::character varying::text])", name: "invitation_email_attempts_status_valid"
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
    t.check_constraint "source::text = ANY (ARRAY['user_confirmed'::character varying::text, 'system_inferred'::character varying::text, 'coach_confirmed'::character varying::text])", name: "merchant_category_rules_source_valid"
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
    t.check_constraint "request_kind::text = ANY (ARRAY['apply'::character varying::text, 'cancel'::character varying::text])", name: "mia_plan_applications_request_kind_valid"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "mia_plan_applications_status_valid"
  end

  create_table "mia_action_drafts", force: :cascade do |t|
    t.datetime "applied_at"
    t.bigint "applied_by_user_id"
    t.bigint "assistant_chat_message_id"
    t.datetime "canceled_at"
    t.bigint "canceled_by_user_id"
    t.datetime "created_at", null: false
    t.string "draft_type", default: "budget_edit", null: false
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
    t.check_constraint "draft_type::text = ANY (ARRAY['budget_edit'::character varying::text, 'household_setup'::character varying::text, 'income_schedule'::character varying::text, 'debt_plan'::character varying::text, 'asset_plan'::character varying::text, 'goal_plan'::character varying::text, 'action_plan'::character varying::text])", name: "mia_action_drafts_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'partially_applied'::character varying::text, 'applied'::character varying::text, 'canceled'::character varying::text])", name: "mia_action_drafts_status_valid"
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
    t.check_constraint "action_type::text = ANY (ARRAY['create_category'::character varying::text, 'update_category'::character varying::text, 'update_allocation'::character varying::text, 'archive_category'::character varying::text, 'restore_category'::character varying::text, 'update_setup_value'::character varying::text, 'upsert_income_schedule_entry'::character varying::text, 'create_income_source'::character varying::text, 'update_income_source'::character varying::text, 'archive_income_source'::character varying::text, 'restore_income_source'::character varying::text, 'create_income_schedule_entry'::character varying::text, 'update_income_schedule_entry'::character varying::text, 'delete_income_schedule_entry'::character varying::text, 'create_debt'::character varying::text, 'update_debt'::character varying::text, 'archive_debt'::character varying::text, 'restore_debt'::character varying::text, 'update_debt_tracking'::character varying::text, 'create_account'::character varying::text, 'update_account'::character varying::text, 'archive_account'::character varying::text, 'restore_account'::character varying::text, 'link_plaid_account'::character varying::text, 'reconcile_plaid_account'::character varying::text, 'unlink_plaid_account'::character varying::text, 'create_goal'::character varying::text, 'update_goal'::character varying::text, 'archive_goal'::character varying::text, 'restore_goal'::character varying::text, 'update_runway_policy'::character varying::text, 'update_transition_policy'::character varying::text, 'update_household_profile'::character varying::text, 'confirm_household_setup'::character varying::text])", name: "mia_action_items_action_type_valid"
    t.check_constraint "jsonb_typeof(dependencies) = 'array'::text", name: "mia_action_items_dependencies_array"
    t.check_constraint "jsonb_typeof(prepared_operation) = 'object'::text", name: "mia_action_items_prepared_operation_object"
    t.check_constraint "operation_key IS NULL AND operation_version IS NULL AND prepared_operation_fingerprint IS NULL AND prepared_operation = '{}'::jsonb OR operation_key IS NOT NULL AND operation_version > 0 AND prepared_operation_fingerprint IS NOT NULL AND prepared_operation <> '{}'::jsonb", name: "mia_action_items_operation_identity_complete"
    t.check_constraint "source_start IS NULL AND source_end IS NULL OR source_start >= 0 AND source_end > source_start", name: "mia_action_items_source_span_valid"
  end

  create_table "mia_message_requests", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "request_fingerprint", null: false
    t.string "request_key", null: false
    t.jsonb "response_payload", default: {}, null: false
    t.integer "response_status"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "request_key"], name: "index_mia_message_requests_on_chat_session_id_and_request_key", unique: true
    t.index ["chat_session_id"], name: "index_mia_message_requests_on_chat_session_id"
    t.check_constraint "char_length(request_key::text) >= 1 AND char_length(request_key::text) <= 100", name: "mia_message_requests_key_length"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "mia_message_requests_status_valid"
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
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "workflow", null: false
    t.index ["household_id"], name: "index_pilot_feedback_reports_on_household_id"
    t.index ["status", "created_at"], name: "index_pilot_feedback_reports_on_status_and_created_at"
    t.index ["user_id"], name: "index_pilot_feedback_reports_on_user_id"
    t.check_constraint "status::text = ANY (ARRAY['submitted'::character varying::text, 'reviewed'::character varying::text, 'resolved'::character varying::text])", name: "pilot_feedback_reports_status_valid"
    t.check_constraint "workflow::text = ANY (ARRAY['sign_in'::character varying::text, 'home'::character varying::text, 'setup'::character varying::text, 'ask_mia'::character varying::text, 'voice'::character varying::text, 'budget'::character varying::text, 'transaction_review'::character varying::text, 'receipt_upload'::character varying::text, 'statement_upload'::character varying::text, 'document_upload'::character varying::text, 'private_document'::character varying::text, 'admin'::character varying::text, 'other'::character varying::text])", name: "pilot_feedback_reports_workflow_valid"
  end

  create_table "plaid_accounts", force: :cascade do |t|
    t.string "account_subtype"
    t.string "account_type", null: false
    t.boolean "active", default: true, null: false
    t.bigint "available_balance_cents"
    t.datetime "created_at", null: false
    t.bigint "current_balance_cents"
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
    t.check_constraint "environment::text = ANY (ARRAY['sandbox'::character varying::text, 'production'::character varying::text])", name: "plaid_items_environment"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'update_required'::character varying::text, 'error'::character varying::text, 'disconnecting'::character varying::text, 'disconnected'::character varying::text])", name: "plaid_items_status"
  end

  create_table "plaid_transactions", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.date "authorized_on"
    t.datetime "created_at", null: false
    t.string "detailed_category"
    t.string "drafted_source_fingerprint"
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
    t.check_constraint "review_status::text = ANY (ARRAY['unreviewed'::character varying::text, 'drafted'::character varying::text, 'ignored'::character varying::text])", name: "plaid_transactions_review_status"
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
    t.check_constraint "status::text = ANY (ARRAY['proposed'::character varying::text, 'accepted'::character varying::text, 'rejected'::character varying::text])", name: "transaction_draft_matches_status_valid"
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
    t.check_constraint "stack_key IS NULL OR (stack_key::text = ANY (ARRAY['non_discretionary'::character varying::text, 'discretionary'::character varying::text, 'sinking_expected'::character varying::text, 'sinking_unexpected'::character varying::text]))", name: "transaction_draft_splits_stack_key_valid"
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
    t.check_constraint "source_type::text = ANY (ARRAY['manual_chat'::character varying::text, 'manual_ui'::character varying::text, 'receipt'::character varying::text, 'screenshot'::character varying::text, 'statement'::character varying::text, 'import'::character varying::text, 'plaid'::character varying::text])", name: "transaction_drafts_source_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'confirmed'::character varying::text, 'corrected'::character varying::text, 'ignored'::character varying::text, 'matched'::character varying::text])", name: "transaction_drafts_status_valid"
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
    t.check_constraint "invitation_email_status::text = ANY (ARRAY['not_sent'::character varying::text, 'skipped'::character varying::text, 'sent'::character varying::text, 'failed'::character varying::text])", name: "users_invitation_email_status_valid"
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
    t.check_constraint "event_type::text = ANY (ARRAY['publish'::character varying::text, 'rollback'::character varying::text])", name: "workspace_brand_publication_events_type"
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
  add_foreign_key "budget_allocations", "budget_categories"
  add_foreign_key "budget_allocations", "budget_periods"
  add_foreign_key "budget_categories", "households"
  add_foreign_key "budget_periods", "budget_years"
  add_foreign_key "budget_years", "households"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_messages", "coach_persona_versions"
  add_foreign_key "chat_messages", "cohort_releases", column: ["cohort_release_id", "cohort_id"], primary_key: ["id", "cohort_id"], name: "fk_chat_messages_release_cohort", on_delete: :restrict
  add_foreign_key "chat_messages", "cohort_releases", on_delete: :restrict
  add_foreign_key "chat_messages", "cohorts", on_delete: :restrict
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
  add_foreign_key "expense_items", "households"
  add_foreign_key "financial_document_import_attempts", "financial_document_imports"
  add_foreign_key "financial_document_import_items", "financial_document_imports"
  add_foreign_key "financial_document_import_items", "users", column: "applied_by_user_id"
  add_foreign_key "financial_document_imports", "households"
  add_foreign_key "financial_document_imports", "users", column: "applied_by_user_id"
  add_foreign_key "financial_document_imports", "users", column: "source_deleted_by_user_id"
  add_foreign_key "financial_document_imports", "users", column: "uploaded_by_user_id"
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

      IF NEW.event_type = 'backfill' THEN
        IF NEW.from_cohort_release_id IS NOT NULL THEN
          RAISE EXCEPTION 'runtime backfill may only activate a cohort without an active release'
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
end
