require "test_helper"

class HouseholdFinanceProfileCompletenessCalculatorTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test "an income source that has ended does not count as current setup income" do
    travel_to Date.new(2026, 8, 25) do
      user = User.create!(
        clerk_id: "clerk_#{SecureRandom.hex(6)}",
        email: "#{SecureRandom.hex(6)}@example.com",
        role: "participant",
        invitation_status: "accepted"
      )
      household = Household.create!(created_by_user: user, name: "Completeness Test")
      source = household.income_sources.create!(
        label: "Former salary",
        source_type: "job",
        amount_cents: 500_000,
        cadence: "monthly"
      )
      source.income_schedule_entries.create!(
        entry_type: "recurring_change",
        amount_cents: 0,
        cadence: "monthly",
        effective_on: Date.new(2026, 8, 1)
      )

      result = HouseholdFinance::ProfileCompletenessCalculator.new(household).call

      assert_equal 14, result
    end
  end
end
