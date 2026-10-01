require "test_helper"
require Rails.root.join("db/migrate/20261002130000_add_tracked_goal_lifecycle").to_s

class AddTrackedGoalLifecycleTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "goal_migration_#{SecureRandom.hex(8)}",
      email: "goal-migration-#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "archives duplicate active tracked goals deterministically before adding the unique index" do
    connection = ApplicationRecord.connection
    index_name = "index_goals_on_active_tracked_identity"
    connection.remove_index(:goals, name: index_name) if connection.index_name_exists?(:goals, index_name)
    timestamp = Time.current
    Goal.insert_all!([
      goal_row(label: "Family trip", priority: 1, timestamp: timestamp),
      goal_row(label: "FAMILY TRIP", priority: 2, timestamp: timestamp)
    ])

    AddTrackedGoalLifecycle.new.archive_duplicate_active_tracked_goals!

    records = @household.goals.tracked.order(:priority).to_a
    assert records.first.active?
    assert_not records.second.active?
    assert records.second.archived_at.present?
  ensure
    Goal.where(household_id: @household&.id).delete_all if @household
    unless connection&.indexes(:goals)&.any? { |index| index.name == index_name }
      connection.add_index :goals, "household_id, LOWER(label), goal_type", unique: true,
        where: "record_kind = 'tracked' AND active = TRUE", name: index_name
    end
  end

  private

  def goal_row(label:, priority:, timestamp:)
    {
      household_id: @household.id, label: label, goal_type: "travel", priority: priority,
      target_amount_cents: 0, current_amount_cents: 0, target_amount_known: false,
      current_amount_known: false, record_kind: "tracked", active: true, archived_at: nil,
      source_type: "manual_ui", source_metadata: {}, created_at: timestamp, updated_at: timestamp
    }
  end
end
