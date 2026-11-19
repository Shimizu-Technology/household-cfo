require "test_helper"

class HouseholdFinanceMiaEvalChecksTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  Rules = HouseholdFinance::MiaEvalRules

  test "expected_amounts accepts cents and dollar strings and rounds only whole-dollar figures" do
    eval_case = { "id" => "literal", "prompt" => "How much?", "expected_amounts" => [ 4_500, "$1,234.56", "$2,238.48" ] }

    passing = harness([ eval_case ], "You spent $45 at Cafe, $1,234.56 in all, and $2,238 so far.").call
    assert passing.passed?, passing.failures.map(&:problems).inspect

    failure = harness([ eval_case ], "You spent $45.10 at Cafe and $1,234 in all.").call.failures.sole
    assert_equal [ "$45", "$1,234.56", "$2,238.48" ], failure.missing_amounts
    assert_raises(ArgumentError) { HouseholdFinance::MiaEvalAmounts.cents("about forty") }
  end

  test "ledger amounts come from the runner's snapshot and must appear in the reply" do
    spec = { "ledger" => "month_spending", "month" => "2026-07" }
    eval_case = { "id" => "ledger", "prompt" => "How much did I spend this month?", "expected_amounts" => [ spec ] }
    ledger = { "amounts" => { HouseholdFinance::MiaEvalLedger.spec_key(spec) => 223_848 } }

    assert harness([ eval_case ], { response: "Confirmed spending is $2,238.48.", ledger: ledger }).call.passed?

    wrong = harness([ eval_case ], { response: "Confirmed spending is $2,338.48.", ledger: ledger }).call.failures.sole
    assert_equal [ "month_spending month 2026-07 ($2,238.48)" ], wrong.missing_amounts

    without_ledger = harness([ eval_case ], "Confirmed spending is $2,238.48.").call.failures.sole
    assert_equal [ "month_spending month 2026-07 (no ledger from the runner)" ], without_ledger.missing_amounts
  end

  test "strict_amounts fails a figure that matches neither the expected nor the allowed amounts" do
    eval_case = { "id" => "strict", "prompt" => "Can I afford a $650 TV?", "strict_amounts" => true,
      "expected_amounts" => [ "$650", "$1,320" ], "allowed_amounts" => [ "$670" ] }

    assert harness([ eval_case ], "Your plan has $1,320 left, so a $650 TV would leave $670.").call.passed?
    failure = harness([ eval_case ], "Your plan has $1,320 left, so a $650 TV would leave $570.").call.failures.sole
    assert_equal [ "$570" ], failure.unexpected_amounts
    assert_empty failure.missing_amounts
  end

  test "the ledger reads Budget, the plan and debts the way the app does" do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time do
      _user, household = HouseholdFinance::MiaEvalCfoHousehold.create!
      ledger = HouseholdFinance::MiaEvalLedger.new(household)
      budget = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).read_only_plan_data.deep_symbolize_keys
      patterns = SpendingPatterns::Analyzer.new(household, from: "2026-04-01", to: "2026-07-15").call

      (4..7).each do |month|
        spent = ledger.amount("ledger" => "month_spending", "month" => format("2026-%02d", month))
        assert_equal budget[:rows].sum { |row| HouseholdFinance::Money.cents(row[:months][month - 1][:actual]) }, spent
        # Mia's pattern totals count the same purchases as Budget.
        assert_equal patterns[:coverage][:months].find { |row| row[:month] == format("2026-%02d", month) }[:spending_cents], spent
      end
      assert_equal 379_848, ledger.amount("ledger" => "month_spending", "month" => "2026-06")
      assert_equal 990_244, ledger.amount("ledger" => "month_spending", "month" => "2026-04", "through" => "2026-06")
      assert_equal 364_000, ledger.amount("ledger" => "month_planned", "month" => "2026-06")
      assert_equal 540_000, ledger.amount("ledger" => "month_income", "month" => "2026-06")
      assert_equal 132_000, ledger.amount("ledger" => "month_plan_left", "month" => "2026-07")
      assert_equal 67_000, ledger.amount("ledger" => "month_plan_left", "month" => "2026-07", "minus" => "$650")
      assert_equal 13_000, ledger.amount("ledger" => "category_spending", "category" => "Dining Out", "month" => "2026-06")
      assert_equal 44_000, ledger.amount("ledger" => "debt_minimums")

      snapshot = HouseholdFinance::MiaEvalLedger.snapshot(household, "expected_amounts" => [ { "ledger" => "category_spending", "category" => "Travel" } ])
      assert_match(/no category named "Travel"/, snapshot["amounts"].values.sole["unavailable"])
      assert_equal 223_848, snapshot.dig("month_spending", "2026-07")
      assert_includes snapshot["protected_names"], "Medical"
      assert_includes snapshot["protected_names"], "Island Prenatal Clinic"
      assert_includes snapshot["protected_names"], "Zelle to Auntie Lina"
      assert_not_includes snapshot["protected_names"], "Jamaican Grill"
      assert_equal [ "PayPal *IslandNursery" ], snapshot["one_month_merchants"]
    end
  end

  test "protected_cut catches a cut that names protected spending and ignores a refusal" do
    ledger = { "protected_names" => [ "Island Prenatal Clinic", "Zelle to Auntie Lina" ] }

    [
      "Spending half as much at Island Prenatal Clinic could free about $102 a month.",
      "You could cut back on medical visits for a while.",
      "Try to stop sending money to Zelle to Auntie Lina this month.",
      "Would you feel more comfortable cutting back on Jamaican Grill, Ross, or Island Prenatal Clinic?"
    ].each do |reply|
      assert_equal [ "protected_cut" ], rules_for(reply, ledger: ledger), reply
    end
    [
      "I would never suggest cutting medical care or family support.",
      "Rent and power stay protected, so cut back on Jamaican Grill instead.",
      "Cut back on Jamaican Grill, not rent.",
      "Trim flexible spending and keep medical care as it is.",
      "Spending half as much at Jamaican Grill could free about $44 a month."
    ].each do |reply|
      assert_empty rules_for(reply, ledger: ledger), reply
    end
  end

  test "one_month_saving catches a monthly saving from a store seen once" do
    ledger = { "one_month_merchants" => [ "PayPal *IslandNursery" ] }

    assert_equal [ "one_month_saving" ], rules_for("Spending half as much at PayPal *IslandNursery could free about $345 a month.", ledger: ledger)
    assert_empty rules_for("The PayPal *IslandNursery payment was one-time, so it is not a monthly saving.", ledger: ledger)
    assert_empty rules_for("Spending half as much at Jamaican Grill could free about $44 a month.", ledger: ledger)
    assert_empty rules_for("Spending half as much at PayPal *IslandNursery could free about $345 a month.")
  end

  test "raw_bank_descriptor catches the bank's wording around a store name" do
    assert_equal %w[raw_bank_descriptor raw_bank_descriptor raw_bank_descriptor],
      rules_for("Top merchants: Purchase authorized on 06/20 Reef Coffee Co Hagatna GU S*····4410 Card 7302 $38.")
    assert_equal [ "raw_bank_descriptor" ], rules_for("Recurring Payment authorized on 07/05 Spotify USA $11.99")
    assert_equal [ "raw_bank_descriptor" ], rules_for("Online transfer on 09/10 Ref # Demo1A2B3C4D")
    assert_empty rules_for("Reef Coffee Co ($38) and Spotify USA ($11.99) on the card ending 7302 in 2026.")
  end

  test "income_answered_with_spending catches spending given for an income question" do
    ledger = { "month_spending" => { "2026-06" => 379_848 } }

    travel_to HouseholdFinance::MiaEvalHousehold.eval_time do
      assert_includes rules_for("For June 2026, confirmed spending is $3,798.48.", prompt: "How much came in last month?", ledger: ledger), "income_answered_with_spending"
      assert_equal [ "income_answered_with_spending" ], rules_for("June 2026 was $3,798.48.", prompt: "How much came in last month?", ledger: ledger)
      assert_empty rules_for("Your plan counts $5,400 coming in for June 2026.", prompt: "How much came in last month?", ledger: ledger)
      assert_empty rules_for("For June 2026, confirmed spending is $3,798.48.", prompt: "How much did we spend last month?", ledger: ledger)
    end
  end

  test "a case skips a rule only with a reason and a known rule name" do
    eval_case = { "id" => "skip", "prompt" => "Show me the statement line.", "skip_rules" => { "raw_bank_descriptor" => "She asked for the line as the bank wrote it." } }
    assert harness([ eval_case ], "Purchase authorized on 06/20 Reef Coffee Co").call.passed?

    error = assert_raises(ArgumentError) { harness([ eval_case.merge("skip_rules" => { "raw_bank_descriptor" => " " }) ], "") }
    assert_match(/needs a reason/, error.message)
    error = assert_raises(ArgumentError) { harness([ eval_case.merge("skip_rules" => { "tone" => "no" }) ], "") }
    assert_match(/unknown rule "tone"/, error.message)
  end

  test "a known gap reports without failing and is listed as closed once it passes" do
    gap = { "id" => "gap", "prompt" => "Will we make it to payday?", "expected_phrases" => [ "payday" ], "known_gap" => true, "gap_reason" => "No payday answer yet." }
    regular = { "id" => "regular", "prompt" => "Hi", "expected_phrases" => [ "hello" ] }

    open = harness([ gap, regular ], "hello").call
    assert open.passed?
    assert_equal [ "gap" ], open.known_gaps.map(&:id)
    assert_equal "No payday answer yet.", open.known_gaps.sole.gap_reason
    assert_equal [ "missing phrases: [\"payday\"]" ], open.known_gaps.sole.problems
    assert_empty open.closed_gaps

    closed = harness([ gap, regular ], "hello, you'll make it to payday").call
    assert_equal [ "gap" ], closed.closed_gaps.map(&:id)
    assert_empty closed.known_gaps

    assert_not harness([ gap, regular ], "nope").call.passed?
    assert_raises(ArgumentError) { harness([ gap.except("gap_reason") ], "") }
  end

  test "the rules apply to every case through the harness, in live mode too" do
    eval_case = { "id" => "descriptor", "prompt" => "What did I buy?" }
    [ :deterministic, :live ].each do |mode|
      failure = harness([ eval_case ], "Purchase authorized on 06/20 Reef Coffee Co", mode: mode).call.failures.sole
      assert_equal [ "raw_bank_descriptor" ], failure.rule_violations.pluck("rule")
    end
  end

  private

  def harness(cases, reply, mode: :deterministic)
    HouseholdFinance::MiaEvalHarness.new(cases: cases, mode: mode, runner: ->(_eval_case) { reply })
  end

  def rules_for(reply, prompt: "What should I do?", ledger: nil)
    Rules.violations(prompt: prompt, response: reply, ledger: ledger).pluck("rule")
  end
end
