require "test_helper"
require Rails.root.join("db/migrate/20261001090000_add_temporal_boundaries_to_income_sources").to_s

class AddTemporalBoundariesToIncomeSourcesTest < ActiveSupport::TestCase
  test "rollback is explicitly irreversible because it would erase timeline history" do
    user = User.create!(clerk_id: "income_migration_#{SecureRandom.hex(8)}", email: "income-migration-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    source = household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1))
    entry = source.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 600_000, cadence: "monthly", effective_on: Date.new(2026, 10, 1))
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddTemporalBoundariesToIncomeSources.new.migrate(:down)
    end

    assert_includes error.message, "cannot be removed without losing financial history"
    assert_equal 500_000, IncomeSource.find(source.id).amount_cents
    assert_equal 600_000, IncomeScheduleEntry.find(entry.id).amount_cents
    assert ApplicationRecord.connection.indexes(:income_sources).any? { |index| index.name == AddTemporalBoundariesToIncomeSources::NEW_INDEX }
  end
end
