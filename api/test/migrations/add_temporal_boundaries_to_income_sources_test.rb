require "test_helper"
require Rails.root.join("db/migrate/20261001090000_add_temporal_boundaries_to_income_sources").to_s

class AddTemporalBoundariesToIncomeSourcesTest < ActiveSupport::TestCase
  test "down and up preserve legacy income source and schedule data" do
    user = User.create!(clerk_id: "income_migration_#{SecureRandom.hex(8)}", email: "income-migration-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    source = household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1))
    entry = source.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 600_000, cadence: "monthly", effective_on: Date.new(2026, 10, 1))
    migration = AddTemporalBoundariesToIncomeSources.new
    migrated_down = false

    migration.migrate(:down)
    migrated_down = true
    IncomeSource.reset_column_information
    assert_equal 500_000, IncomeSource.find(source.id).amount_cents
    assert_equal 600_000, IncomeScheduleEntry.find(entry.id).amount_cents
    assert ApplicationRecord.connection.indexes(:income_sources).any? { |index| index.name == AddTemporalBoundariesToIncomeSources::OLD_INDEX }

    migration.migrate(:up)
    migrated_down = false
    IncomeSource.reset_column_information
    restored = IncomeSource.find(source.id)
    assert_nil restored.starts_on
    assert_nil restored.ends_on
    assert_equal 600_000, restored.income_schedule_entries.find(entry.id).amount_cents
    assert ApplicationRecord.connection.indexes(:income_sources).any? { |index| index.name == AddTemporalBoundariesToIncomeSources::NEW_INDEX }
  ensure
    migration&.migrate(:up) if migrated_down
    IncomeSource.reset_column_information
    MiaActionItem.reset_column_information
  end
end
