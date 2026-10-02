class AddCompoundMiaActionPlans < ActiveRecord::Migration[8.0]
  ACTION_TYPES = %w[
    create_category update_category update_allocation archive_category restore_category
    update_setup_value upsert_income_schedule_entry create_income_source update_income_source
    archive_income_source restore_income_source create_income_schedule_entry update_income_schedule_entry
    delete_income_schedule_entry create_debt update_debt archive_debt restore_debt update_debt_tracking
    create_account update_account archive_account restore_account link_plaid_account reconcile_plaid_account unlink_plaid_account
    create_goal update_goal archive_goal restore_goal update_runway_policy update_transition_policy update_household_profile confirm_household_setup
  ].freeze

  def up
    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_status_valid"
    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"

    add_check_constraint :mia_action_drafts,
      "status IN ('pending', 'partially_applied', 'applied', 'canceled')",
      name: "mia_action_drafts_status_valid"
    add_check_constraint :mia_action_drafts,
      "draft_type IN ('budget_edit', 'household_setup', 'income_schedule', 'debt_plan', 'asset_plan', 'goal_plan', 'action_plan')",
      name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN (#{ACTION_TYPES.map { |value| connection.quote(value) }.join(', ')})",
      name: "mia_action_items_action_type_valid"

    add_column :mia_action_items, :source_text, :text
    add_column :mia_action_items, :source_start, :integer
    add_column :mia_action_items, :source_end, :integer
    add_column :mia_action_items, :dependencies, :jsonb, default: [], null: false
    add_column :mia_action_items, :applied_at, :datetime
    add_column :mia_action_items, :canceled_at, :datetime
    add_reference :mia_action_items, :canceled_by_user, foreign_key: { to_table: :users }
    add_check_constraint :mia_action_items, "jsonb_typeof(dependencies) = 'array'", name: "mia_action_items_dependencies_array"
    add_check_constraint :mia_action_items,
      "source_start IS NULL AND source_end IS NULL OR source_start >= 0 AND source_end > source_start",
      name: "mia_action_items_source_span_valid"

    create_table :mia_action_draft_applications do |t|
      t.references :mia_action_draft, null: false, foreign_key: true
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :idempotency_key, null: false
      t.string :request_fingerprint, null: false
      t.string :request_kind, default: "apply", null: false
      t.jsonb :selected_item_ids, default: [], null: false
      t.string :status, default: "processing", null: false
      t.jsonb :response_payload, default: {}, null: false
      t.datetime :completed_at
      t.timestamps
    end
    add_index :mia_action_draft_applications, [ :household_id, :user_id, :idempotency_key ], unique: true,
      name: "index_mia_plan_applications_on_actor_and_key"
    add_check_constraint :mia_action_draft_applications,
      "char_length(idempotency_key) BETWEEN 1 AND 200",
      name: "mia_plan_applications_key_length"
    add_check_constraint :mia_action_draft_applications,
      "jsonb_typeof(selected_item_ids) = 'array'",
      name: "mia_plan_applications_selected_ids_array"
    add_check_constraint :mia_action_draft_applications,
      "status IN ('processing', 'completed', 'failed')",
      name: "mia_plan_applications_status_valid"
    add_check_constraint :mia_action_draft_applications,
      "request_kind IN ('apply', 'cancel')",
      name: "mia_plan_applications_request_kind_valid"
  end

  def down
    drop_table :mia_action_draft_applications
    remove_check_constraint :mia_action_items, name: "mia_action_items_source_span_valid"
    remove_check_constraint :mia_action_items, name: "mia_action_items_dependencies_array"
    remove_columns :mia_action_items, :source_text, :source_start, :source_end, :dependencies, :applied_at,
      :canceled_at, :canceled_by_user_id

    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_status_valid"
    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_drafts, "status IN ('pending', 'applied', 'canceled')", name: "mia_action_drafts_status_valid"
    add_check_constraint :mia_action_drafts,
      "draft_type IN ('budget_edit', 'household_setup', 'income_schedule', 'debt_plan', 'asset_plan', 'goal_plan')",
      name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN (#{(ACTION_TYPES - %w[update_runway_policy update_transition_policy update_household_profile confirm_household_setup]).map { |value| connection.quote(value) }.join(', ')})",
      name: "mia_action_items_action_type_valid"
  end
end
