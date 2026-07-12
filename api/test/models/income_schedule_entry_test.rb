require "test_helper"

class IncomeScheduleEntryTest < ActiveSupport::TestCase
  test "recurring and one-time entries enforce their cadence" do
    household = create_household
    source = household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 100_000, cadence: "monthly")

    recurring = source.income_schedule_entries.new(entry_type: "recurring_change", amount_cents: 120_000, cadence: "one_time", effective_on: Date.new(2026, 8, 1))
    refute recurring.valid?
    assert_includes recurring.errors[:cadence], "cannot be one_time for a recurring change"

    bonus = source.income_schedule_entries.new(entry_type: "one_time", amount_cents: 50_000, cadence: "monthly", effective_on: Date.new(2026, 12, 1))
    refute bonus.valid?
    assert_includes bonus.errors[:cadence], "must be one_time for a one-time entry"

    empty_bonus = source.income_schedule_entries.new(entry_type: "one_time", amount_cents: 0, cadence: "one_time", effective_on: Date.new(2026, 12, 1))
    refute empty_bonus.valid?
    assert_includes empty_bonus.errors[:amount_cents], "must be greater than zero for one-time income"
  end

  test "only one recurring change can start for a source in a month while multiple one-time entries are allowed" do
    household = create_household
    source = household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 100_000, cadence: "monthly")
    source.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 120_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
    duplicate = source.income_schedule_entries.new(entry_type: "recurring_change", amount_cents: 130_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))

    refute duplicate.valid?
    assert_includes duplicate.errors[:effective_on], "has already been taken"

    source.income_schedule_entries.create!(entry_type: "one_time", label: "Bonus", amount_cents: 50_000, cadence: "one_time", effective_on: Date.new(2026, 12, 1))
    reimbursement = source.income_schedule_entries.new(entry_type: "one_time", label: "Reimbursement", amount_cents: 20_000, cadence: "one_time", effective_on: Date.new(2026, 12, 1))
    assert reimbursement.valid?
  end

  private

  def create_household
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    Household.create!(created_by_user: user, name: "Income schedule household")
  end
end
