require "test_helper"
require Rails.root.join("db/migrate/20261001080000_create_household_operation_executions").to_s
require Rails.root.join("db/migrate/20261001080100_validate_mia_action_item_operation_constraints").to_s

class CreateHouseholdOperationExecutionsTest < ActiveSupport::TestCase
  test "down and up preserve existing Mia items as true all-null legacy tuples" do
    user = User.create!(
      clerk_id: "operation_migration_#{SecureRandom.hex(8)}",
      email: "operation-migration-#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    draft = household.mia_action_drafts.create!(
      requested_by_user: user, draft_type: "household_setup", status: "pending",
      year: 2026, title: "Legacy review", summary: "Existing review"
    )
    item = draft.mia_action_items.create!(
      position: 0, action_type: "update_setup_value", label: "Legacy item",
      payload: { key: "household_name", value: "Cruz" },
      before_snapshot: { value: household.name }, after_snapshot: { value: "Cruz" }
    )
    creation_migration = CreateHouseholdOperationExecutions.new
    validation_migration = ValidateMiaActionItemOperationConstraints.new
    creation_migrated_down = false
    validation_migrated_down = false

    validation_migration.migrate(:down)
    validation_migrated_down = true
    assert constraint_validated?("mia_action_items_operation_identity_complete")
    assert constraint_validated?("mia_action_items_prepared_operation_object")

    creation_migration.migrate(:down)
    creation_migrated_down = true
    assert_equal item.id, ApplicationRecord.connection.select_value("SELECT id FROM mia_action_items WHERE id = #{item.id.to_i}").to_i

    creation_migration.migrate(:up)
    creation_migrated_down = false
    refute constraint_validated?("mia_action_items_operation_identity_complete")
    refute constraint_validated?("mia_action_items_prepared_operation_object")

    validation_migration.migrate(:up)
    validation_migrated_down = false
    assert constraint_validated?("mia_action_items_operation_identity_complete")
    assert constraint_validated?("mia_action_items_prepared_operation_object")
    MiaActionItem.reset_column_information
    legacy = MiaActionItem.find(item.id)
    assert_nil legacy.operation_key
    assert_nil legacy.operation_version
    assert_nil legacy.prepared_operation_fingerprint
    assert_equal({}, legacy.prepared_operation)
  ensure
    creation_migration&.migrate(:up) if creation_migrated_down
    validation_migration&.migrate(:up) if validation_migrated_down
    MiaActionItem.reset_column_information
    HouseholdOperationExecution.reset_column_information if defined?(HouseholdOperationExecution)
  end

  private

  def constraint_validated?(name)
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql_array([
        "SELECT convalidated FROM pg_constraint WHERE conname = ? AND conrelid = 'mia_action_items'::regclass",
        name
      ])
    )
  end
end
