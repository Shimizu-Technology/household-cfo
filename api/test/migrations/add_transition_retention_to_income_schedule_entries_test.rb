require "test_helper"
require Rails.root.join("db/migrate/20260825010000_add_transition_retention_to_income_schedule_entries").to_s

class AddTransitionRetentionToIncomeScheduleEntriesTest < ActiveSupport::TestCase
  test "preserves only explicit legacy reduced-hours intent and never approves ambiguous departures" do
    explicit = create_income_change(goal: "Reduce my work hours and build the business")
    part_time = create_income_change(goal: "Move to part-time work while growing the business")
    shifts = create_income_change(goal: "Scale back my shifts as the business grows")
    departure = create_income_change(goal: "Stop working for my employer and build the business")
    mixed_departure = create_income_change(goal: "Reduce my hours until I leave my career")
    ambiguous = create_income_change(goal: "Build the business and protect my family")
    declined = create_income_change(goal: "Reduce my work hours and build the business", retained_after_transition: false)
    business = create_income_change(goal: "Reduce my work hours and build the business", source_type: "business")
    ending = create_income_change(goal: "Reduce my work hours and build the business", amount_cents: 0)

    AddTransitionRetentionToIncomeScheduleEntries.new.send(:preserve_explicit_reduced_hours_intent)

    assert explicit.reload.retained_after_transition?
    assert part_time.reload.retained_after_transition?
    assert shifts.reload.retained_after_transition?
    assert_nil departure.reload.retained_after_transition
    assert_nil mixed_departure.reload.retained_after_transition
    assert_nil ambiguous.reload.retained_after_transition
    assert_equal false, declined.reload.retained_after_transition
    assert_nil business.reload.retained_after_transition
    assert_nil ending.reload.retained_after_transition
  end

  private

  def create_income_change(goal:, source_type: "job", amount_cents: 350_000, retained_after_transition: nil)
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Legacy transition income", primary_goal: goal)
    source = household.income_sources.create!(label: "Scheduled income", source_type: source_type, amount_cents: 600_000, cadence: "monthly")
    source.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: amount_cents,
      cadence: "monthly",
      effective_on: Date.new(2026, 8, 1),
      retained_after_transition: retained_after_transition
    )
  end
end
