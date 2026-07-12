require "test_helper"

class HouseholdFinanceIncomeTimelineTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test "recurring changes affect the current baseline while one-time income stays out of baseline" do
    household = create_household
    source = household.income_sources.create!(label: "Primary", source_type: "job", amount_cents: 100_000, cadence: "monthly")
    source.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 120_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
    source.income_schedule_entries.create!(entry_type: "one_time", label: "Bonus", amount_cents: 50_000, cadence: "one_time", effective_on: Date.new(2026, 8, 1))

    assert_equal 100_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 7, 31))
    assert_equal 120_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 8, 1))
    assert_equal 170_000, HouseholdFinance::IncomeTimeline.period_cents(source, starts_on: Date.new(2026, 8, 1), ends_on: Date.new(2026, 8, 31))
  end

  test "snapshot readiness uses the recurring amount effective in the current month" do
    travel_to Date.new(2026, 8, 12) do
      household = create_household
      source = household.income_sources.create!(label: "Primary", source_type: "job", amount_cents: 100_000, cadence: "monthly")
      source.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 140_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
      source.income_schedule_entries.create!(entry_type: "one_time", label: "Bonus", amount_cents: 50_000, cadence: "one_time", effective_on: Date.new(2026, 8, 1))

      snapshot = HouseholdFinance::SnapshotBuilder.new(household).call

      assert_equal 140_000, snapshot.fetch(:monthly_income_cents)
    end
  end

  private

  def create_household
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    Household.create!(created_by_user: user, name: "Income timeline household")
  end
end
