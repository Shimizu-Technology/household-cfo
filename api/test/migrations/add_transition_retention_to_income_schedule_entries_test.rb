require "test_helper"
require Rails.root.join("db/migrate/20260825010000_add_transition_retention_to_income_schedule_entries").to_s

class AddTransitionRetentionToIncomeScheduleEntriesTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 8, 25, 12)
  end

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

    backfill_legacy_income

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

  test "approves only the current reduction and never preapproves future changes" do
    current = create_income_change(goal: "Reduce my work hours and build the business")
    future = current.income_source.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: 200_000,
      cadence: "monthly",
      effective_on: Date.new(2026, 9, 1)
    )

    backfill_legacy_income

    assert current.reload.retained_after_transition?
    assert_nil future.reload.retained_after_transition
  end

  test "compares the latest effective change with the preceding salary instead of approving past changes" do
    preceding = create_income_change(
      goal: "Reduce my work hours and build the business",
      amount_cents: 800_000,
      effective_on: Date.new(2026, 7, 1)
    )
    reduction = preceding.income_source.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: 700_000,
      cadence: "monthly",
      effective_on: Date.new(2026, 8, 1)
    )

    backfill_legacy_income

    assert_nil preceding.reload.retained_after_transition
    assert reduction.reload.retained_after_transition?
  end

  test "does not approve a raise after an earlier reduction" do
    preceding = create_income_change(
      goal: "Reduce my work hours and build the business",
      effective_on: Date.new(2026, 7, 1)
    )
    raise_entry = preceding.income_source.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: 400_000,
      cadence: "monthly",
      effective_on: Date.new(2026, 8, 1)
    )

    backfill_legacy_income

    assert_nil preceding.reload.retained_after_transition
    assert_nil raise_entry.reload.retained_after_transition
  end

  test "normalizes different pay cadences before recognizing a reduction" do
    reduced = create_income_change(
      goal: "Reduce my work hours and build the business",
      amount_cents: 200_000,
      cadence: "biweekly"
    )
    not_reduced = create_income_change(
      goal: "Reduce my work hours and build the business",
      amount_cents: 300_000,
      cadence: "biweekly"
    )

    backfill_legacy_income

    assert reduced.reload.retained_after_transition?
    assert_nil not_reduced.reload.retained_after_transition
  end

  test "recognizes an annualized cadence reduction even when the current monthly amounts tie" do
    reduced = create_income_change(
      goal: "Reduce my work hours and build the business",
      amount_cents: 4_333,
      cadence: "monthly",
      source_amount_cents: 1_000,
      source_cadence: "weekly"
    )

    backfill_legacy_income

    assert reduced.reload.retained_after_transition?
  end

  test "never approves an inactive salary or an older change when the current change was declined" do
    inactive = create_income_change(goal: "Reduce my work hours and build the business")
    inactive.income_source.update!(active: false)

    older = create_income_change(
      goal: "Reduce my work hours and build the business",
      amount_cents: 450_000,
      effective_on: Date.new(2026, 7, 1)
    )
    declined = older.income_source.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: 350_000,
      cadence: "monthly",
      effective_on: Date.new(2026, 8, 1),
      retained_after_transition: false
    )

    backfill_legacy_income

    assert_nil inactive.reload.retained_after_transition
    assert_nil older.reload.retained_after_transition
    assert_equal false, declined.reload.retained_after_transition
  end

  private

  def backfill_legacy_income
    ActiveRecord::Migration.suppress_messages do
      AddTransitionRetentionToIncomeScheduleEntries.new.send(:preserve_explicit_reduced_hours_intent)
    end
  end

  def create_income_change(goal:, source_type: "job", amount_cents: 350_000, cadence: "monthly",
                           source_amount_cents: 600_000, source_cadence: "monthly",
                           effective_on: Date.new(2026, 8, 1), retained_after_transition: nil)
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Legacy transition income", primary_goal: goal)
    source = household.income_sources.create!(label: "Scheduled income", source_type: source_type, amount_cents: source_amount_cents, cadence: source_cadence)
    source.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: amount_cents,
      cadence: cadence,
      effective_on: effective_on,
      retained_after_transition: retained_after_transition
    )
  end
end
