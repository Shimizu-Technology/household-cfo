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

ActiveRecord::Schema[8.1].define(version: 2026_06_21_010000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "account_type", default: "other", null: false
    t.integer "balance_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "label", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "account_type"], name: "index_accounts_on_household_id_and_account_type"
    t.index ["household_id"], name: "index_accounts_on_household_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "created_at"], name: "index_chat_messages_on_chat_session_id_and_created_at"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["role"], name: "index_chat_messages_on_role"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "household_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["household_id", "user_id"], name: "index_chat_sessions_on_household_id_and_user_id"
    t.index ["household_id"], name: "index_chat_sessions_on_household_id"
    t.index ["user_id"], name: "index_chat_sessions_on_user_id"
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
    t.index ["household_id", "debt_type"], name: "index_debts_on_household_id_and_debt_type"
    t.index ["household_id"], name: "index_debts_on_household_id"
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
    t.index ["household_id", "stack_key"], name: "index_expense_items_on_household_id_and_stack_key"
    t.index ["household_id"], name: "index_expense_items_on_household_id"
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
    t.index ["household_id", "source_type"], name: "index_income_sources_on_household_id_and_source_type"
    t.index ["household_id"], name: "index_income_sources_on_household_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "accepted_at"
    t.string "clerk_id", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "first_name"
    t.string "invitation_status", default: "accepted", null: false
    t.datetime "invited_at"
    t.string "last_name"
    t.datetime "last_sign_in_at"
    t.string "role", default: "participant", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.index ["clerk_id"], name: "index_users_on_clerk_id", unique: true
    t.index ["invitation_status"], name: "index_users_on_invitation_status"
    t.index ["role"], name: "index_users_on_role"
  end

  add_foreign_key "accounts", "households"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_sessions", "households"
  add_foreign_key "chat_sessions", "users"
  add_foreign_key "debts", "households"
  add_foreign_key "expense_items", "households"
  add_foreign_key "goals", "households"
  add_foreign_key "household_memberships", "households"
  add_foreign_key "household_memberships", "users"
  add_foreign_key "household_profiles", "households"
  add_foreign_key "households", "users", column: "created_by_user_id"
  add_foreign_key "income_sources", "households"
end
