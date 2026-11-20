require "test_helper"
require Rails.root.join("lib/scorecard/runner")

class ScorecardApprovalSimulatorTest < ActiveSupport::TestCase
  test "corrected same purchase uses the line merchant two days from a receipt and requires the same answer key event" do
    user = User.create!(clerk_id: "simulator-talun", email: "simulator-talun@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    period = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).current_period_for(Date.new(2026, 8, 3))
    receipt = household.household_transactions.create!(budget_period: period, occurred_on: "2026-08-03", merchant: "Talun Demo Market", total_amount_cents: 5000, source_type: "receipt", status: "confirmed")
    simulator = Scorecard::ApprovalSimulator.allocate
    simulator.instance_variable_set(:@household, household)
    simulator.instance_variable_set(:@transaction_answers, { receipt.id => { "event_id" => "talun-groceries" } })
    entry = { edit: { amount_cents: 5000, posted_on: "2026-08-05" } }
    line = Struct.new(:merchant).new("Talun Demo Market")
    assert simulator.send(:corrected_same_purchase?, entry, { "event_id" => "talun-groceries" }, line)
    refute simulator.send(:corrected_same_purchase?, entry, { "event_id" => "talun-other" }, line)
    refute simulator.send(:corrected_same_purchase?, entry.merge(edit: entry[:edit].merge(merchant: "Elsewhere Hardware")), { "event_id" => "talun-groceries" }, line)
  end

  test "a confirmed category joins only the matching store category" do
    simulator = Scorecard::ApprovalSimulator.allocate
    line = Struct.new(:event, :category_id).new(Object.new, 5)
    plan = Object.new
    plan.define_singleton_method(:line_for) { |_| line }
    refute simulator.send(:category_only?, { event_id: 1, decision: "keep" }, plan, 4)
    assert simulator.send(:category_only?, { event_id: 1, decision: "keep" }, plan, 5)
  end

  test "bulk repeats require answer key agreement with the entire offered list" do
    simulator = Scorecard::ApprovalSimulator.allocate
    simulator.instance_variable_set(:@row_answers, (1..3).to_h { |id| [ id + 10, { "event_id" => id, "leg_id" => id } ] })
    lines = (1..3).map { |id| Struct.new(:event, :overlaps).new(Struct.new(:id).new(id), [ { approved_version_id: id, event_id: id + 10 } ]) }
    plan = Struct.new(:repeated_lines).new(lines)
    mappings = (1..3).to_h { |id| [ id, { "event_id" => id, "leg_id" => id } ] }
    mappings[3] = { "event_id" => 99, "leg_id" => 99 }
    assert_empty simulator.send(:confirmed_repeats, plan, mappings)
    mappings[3] = { "event_id" => 3, "leg_id" => 3 }
    assert_equal lines, simulator.send(:confirmed_repeats, plan, mappings)
  end

  test "store category eligibility leaves type and direction corrections individual" do
    simulator = Scorecard::ApprovalSimulator.allocate
    row = Struct.new(:signed_amount_cents, :posted_on).new(-1000, Date.new(2026, 7, 2))
    line = Struct.new(:event).new(row)
    plan = Object.new
    plan.define_singleton_method(:line_for) { |_| line }
    entry = { event_id: 1, decision: "edited", edit: { kind: "spending", amount_cents: 1000, posted_on: "2026-07-02", money_direction: "out", category_id: 4 } }
    assert simulator.send(:category_only?, entry, plan, 4)
    refute simulator.send(:category_only?, entry.merge(edit: entry[:edit].merge(kind: "moved")), plan, 4)
    refute simulator.send(:category_only?, entry.merge(edit: entry[:edit].merge(kind: "money_in", money_direction: "in")), plan, 4)
    refute simulator.send(:category_only?, entry.merge(edit: entry[:edit].merge(money_direction: "in")), plan, 4)
  end

  test "only saved included legs reserve a duplicate key, unsaved retry legs do not" do
    simulator = Scorecard::ApprovalSimulator.allocate
    simulator.instance_variable_set(:@row_answers, { -1 => { "leg_id" => "transfer-out" } })
    simulator.instance_variable_set(:@included_legs, Set.new)
    simulator.send(:record_included_legs, [ { event_id: -1, decision: "pair_transfer" } ])
    assert_empty simulator.instance_variable_get(:@included_legs)
    # A genuinely earlier saved key remains reserved during a later retry.
    simulator.instance_variable_get(:@included_legs) << "earlier-transfer"
    simulator.send(:record_included_legs, [ { event_id: -1, decision: "pair_transfer" } ])
    assert_equal Set["earlier-transfer"], simulator.instance_variable_get(:@included_legs)
  end
  test "a saved same-purchase match remains reserved for later copies" do
    simulator = Scorecard::ApprovalSimulator.allocate
    simulator.instance_variable_set(:@row_answers, { 7 => { "leg_id" => "receipt-bank-leg" } })
    simulator.instance_variable_set(:@included_legs, Set.new)
    head = Struct.new(:approved_version).new(Struct.new(:disposition).new("match"))
    original = SourceReviewHead.method(:find_by)
    SourceReviewHead.define_singleton_method(:find_by) { |**| head }
    begin
      simulator.send(:record_included_legs, [ { event_id: 7, decision: "same_purchase" } ])
    ensure
      SourceReviewHead.define_singleton_method(:find_by, &original)
    end
    assert_equal Set["receipt-bank-leg"], simulator.instance_variable_get(:@included_legs)
  end
  test "one store category action counts separate transfer and money-in corrections" do
    simulator = Scorecard::ApprovalSimulator.allocate
    simulator.instance_variable_set(:@decisions, Hash.new { |hash, month| hash[month] = Hash.new(0) })
    doc = { "period" => { "start_on" => "2026-07-01" } }
    row = Struct.new(:signed_amount_cents, :posted_on, :event_type).new(-1000, Date.new(2026, 7, 2), "purchase")
    entry = { decision: "edited", edit: { category_id: 4, amount_cents: 1000, posted_on: "2026-07-02", kind: "spending", money_direction: "out" } }
    simulator.send(:count, doc, :store_category)
    simulator.send(:count_store_correction, doc, :no_category, nil, entry, row, 4)
    assert_equal 1, simulator.decisions["2026-07"].values.sum
    simulator.send(:count_store_correction, doc, :no_category, nil, entry.merge(edit: entry[:edit].merge(kind: "moved")), row, 4)
    assert_equal 2, simulator.decisions["2026-07"].values.sum
    simulator.send(:count_store_correction, doc, :no_category, nil, entry.merge(edit: entry[:edit].merge(kind: "money_in", money_direction: "in")), row, 4)
    assert_equal 3, simulator.decisions["2026-07"].values.sum
  end
end
