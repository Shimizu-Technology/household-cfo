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

  test "strict_amounts doesn't apply in live runs, where a reply may add other correct figures" do
    eval_case = { "id" => "strict", "prompt" => "Can I afford a $650 TV?", "strict_amounts" => true, "expected_amounts" => [ "$650", "$1,320" ] }
    reply = "Your plan has $1,320 left after $440 of debt minimums on $5,400 coming in, so a $650 TV fits."

    assert harness([ eval_case ], reply, mode: :live).call.passed?
    assert_equal %w[$440 $5,400], harness([ eval_case ], reply).call.failures.sole.unexpected_amounts
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
      # month_planned is the category plan; Budget's "planned out" adds the $440 of debt minimums.
      assert_equal 364_000, ledger.amount("ledger" => "month_planned", "month" => "2026-06")
      assert_equal 408_000, ledger.amount("ledger" => "month_planned_out", "month" => "2026-06")
      assert_equal HouseholdFinance::Money.cents(budget[:annual_outlook][:months].find { |row| row[:starts_on] == "2026-06-01" }[:planned_outflow]),
        ledger.amount("ledger" => "month_planned_out", "month" => "2026-06")
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
      assert_equal 540_000, snapshot.dig("month_income", "2026-06")
      assert_equal [ { "label" => "PayPal *IslandNursery", "total_cents" => 69_000 } ], snapshot["one_month_merchants"]
    end
  end

  test "protected_cut catches a cut that names protected spending and ignores a refusal" do
    [
      "Spending half as much at Island Prenatal Clinic could free about $102 a month.",
      "You could cut back on medical visits for a while.",
      "Try to stop sending money to Zelle to Auntie Lina this month.",
      "Would you feel more comfortable cutting back on Jamaican Grill, Ross, or Island Prenatal Clinic?"
    ].each do |reply|
      assert_equal [ "protected_cut" ], rules_for(reply, ledger: PROTECTED_LEDGER), reply
    end
    [
      "I would never suggest cutting medical care or family support.",
      "Rent and power stay protected, so cut back on Jamaican Grill instead.",
      "Cut back on Jamaican Grill, not rent.",
      "Trim flexible spending and keep medical care as it is.",
      "Spending half as much at Jamaican Grill could free about $44 a month.",
      "Instead of cutting medical care, trim Jamaican Grill."
    ].each do |reply|
      assert_empty rules_for(reply, ledger: PROTECTED_LEDGER), reply
    end
  end

  test "protected_cut knows a person or store by part of its label" do
    [
      "You could stop sending money to Auntie Lina for a few months.",
      "Cut back on what goes to Auntie Lina.",
      "Consider fewer prenatal appointments."
    ].each do |reply|
      assert_equal [ "protected_cut" ], rules_for(reply, ledger: PROTECTED_LEDGER), reply
    end
    assert_empty rules_for("Cut back on what goes to Auntie Lina.")
  end

  test "protected_cut catches lower, skip, pause, put on hold and fewer" do
    [
      "Pausing the $200 to Auntie Lina would free money for the crib.",
      "Maybe put Family Support on hold until the baby comes.",
      "Consider fewer clinic appointments.",
      "Skip the clinic visit this month.",
      "Lower what goes to family for now."
    ].each do |reply|
      assert_equal [ "protected_cut" ], rules_for(reply, ledger: PROTECTED_LEDGER), reply
    end
    assert_empty rules_for("Put $60 toward the crib and keep Netflix on hold.", ledger: PROTECTED_LEDGER)
  end

  test "protected_cut follows a pronoun back to the protected thing named before it" do
    assert_equal [ "protected_cut" ], rules_for("Medical is $205. Could you cut it?", ledger: PROTECTED_LEDGER)
    assert_equal [ "protected_cut" ], rules_for("Medical is $205, so you could trim that.", ledger: PROTECTED_LEDGER)
    assert_empty rules_for("Medical stays as it is. Dining Out is $250; you could trim it.", ledger: PROTECTED_LEDGER)
    assert_empty rules_for("Jamaican Grill is $92. Could you cut it?", ledger: PROTECTED_LEDGER)
  end

  test "protected_cut reads negation only within the cut's own clause" do
    violations = Rules.violations(prompt: "What should I do?", response: "Do not cut rent, but cut Island Prenatal Clinic.", ledger: PROTECTED_LEDGER)
    assert_equal [ "protected_cut" ], violations.pluck("rule")
    assert_empty rules_for("Do not cut rent, but cut Jamaican Grill.", ledger: PROTECTED_LEDGER)
    assert_empty rules_for("Don't cut, trim, or pause medical care.", ledger: PROTECTED_LEDGER)
    # A refusal after the verb.
    assert_empty rules_for("Cutting medical care is not something I'd suggest; trim Jamaican Grill instead.", ledger: PROTECTED_LEDGER)
    assert_equal [ "protected_cut" ], rules_for("Cutting dining is not something I'd suggest; trim the clinic visits instead.", ledger: PROTECTED_LEDGER)
  end

  test "protected_cut ends what is cut at the next clause, so a correct answer passes" do
    [
      "Cutting dining out frees money for the baby.",
      "Skipping takeout would cut $60 a month you could put toward the baby's crib.",
      "Trimming dining could free $40 a month, and the power bill stays as is.",
      "Your spending will drop once the clinic visits end.",
      "Paying the store card first will reduce interest for the family."
    ].each do |reply|
      assert_empty rules_for(reply, ledger: PROTECTED_LEDGER), reply
    end
    assert_equal [ "protected_cut" ], rules_for("Trim dining and the clinic visits.", ledger: PROTECTED_LEDGER)
  end

  test "one_month_saving catches a monthly saving from a store seen once" do
    ledger = { "one_month_merchants" => [ { "label" => "PayPal *IslandNursery", "total_cents" => 69_000 } ] }

    [
      "Spending half as much at PayPal *IslandNursery could free about $345 a month.",
      "Halving that $690 PayPal payment could save $345 a month.",
      "Halving the nursery payment saves $345 a month.",
      # The figure alone: half of the one payment, stated as a month.
      "Trimming that shopping could save $345 a month.",
      # A one-time label elsewhere in the sentence doesn't excuse the monthly claim.
      "The PayPal *IslandNursery payment was one-time, so cutting it saves $345 a month.",
      "The PayPal *IslandNursery payment was one-time, so cutting it saves $200 a month."
    ].each do |reply|
      assert_equal [ "one_month_saving" ], rules_for(reply, ledger: ledger), reply
    end
    # A plain label list, with no totals, still links the pronoun to the store.
    assert_equal [ "one_month_saving" ], rules_for("The PayPal *IslandNursery payment was one-time, so cutting it saves $345 a month.", ledger: { "one_month_merchants" => [ "PayPal *IslandNursery" ] })
    # Without a pronoun, a saving about something else is not tied to the one-off.
    assert_empty rules_for("The PayPal *IslandNursery payment was one-time; trimming dining could save $40 a month.", ledger: ledger)
    [
      "The PayPal *IslandNursery payment was one-time, so it is not a monthly saving.",
      "The $690 to PayPal *IslandNursery was a single payment; there's nothing to save every month.",
      "You cannot save $345 a month by cutting PayPal *IslandNursery.",
      "Spending half as much at Jamaican Grill could free about $44 a month.",
      "Your $690 nursery payment pushed June over; trimming dining could save $40 a month."
    ].each do |reply|
      assert_empty rules_for(reply, ledger: ledger), reply
    end
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
      assert_includes rules_for("Income isn't recorded; you spent $3,798.48.", prompt: "How much came in last month?", ledger: ledger), "income_answered_with_spending"
    end
  end

  test "income_answered_with_spending passes a reply that gives the income and then the spending" do
    reply = "$5,400 came in in June 2026, and you spent $3,798.48, leaving $1,601.52."
    without_income = { "month_spending" => { "2026-06" => 379_848 } }
    with_income = without_income.merge("month_income" => { "2026-06" => 540_000 })

    travel_to HouseholdFinance::MiaEvalHousehold.eval_time do
      assert_empty rules_for(reply, prompt: "How much came in last month?", ledger: without_income)
      assert_empty rules_for(reply, prompt: "How much came in last month?", ledger: with_income)
      # With the plan's income known, the reply has to state that figure.
      assert_includes rules_for("Income was $3,798.48 in June.", prompt: "How much came in last month?", ledger: with_income), "income_answered_with_spending"
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

  test "a known gap reports only the checks it names and is listed as closed once they pass" do
    gap = { "id" => "gap", "prompt" => "Will we make it to payday?", "expected_phrases" => [ "payday" ],
      "known_gap" => { "checks" => [ "expected_phrases" ], "reason" => "No payday answer yet." } }
    regular = { "id" => "regular", "prompt" => "Hi", "expected_phrases" => [ "hello" ] }

    open = harness([ gap, regular ], "hello").call
    assert open.passed?
    assert_equal [ "gap" ], open.known_gaps.map(&:id)
    assert_equal "No payday answer yet.", open.known_gaps.sole.gap_reason
    assert_equal [ "missing phrases: [\"payday\"]" ], open.known_gaps.sole.problems
    assert_empty open.closed_gaps

    closed = harness([ gap, regular ], "hello, you'll make it to payday").call
    assert closed.passed?
    assert_equal [ "gap" ], closed.closed_gaps.map(&:id)
    assert_equal [ "expected_phrases" ], closed.closed_gaps.sole.closed_gap_checks
    assert_match(/known gap checks now passing: expected_phrases/, closed.closed_gaps.sole.problems.join)
    assert_empty closed.known_gaps

    assert_not harness([ gap, regular ], "nope").call.passed?
  end

  test "a known gap never hides a rule or an amount it doesn't name" do
    ledger = { "protected_names" => [ "Island Prenatal Clinic" ] }
    gap = { "id" => "cfo_cut_prenatal_clinic", "prompt" => "Should we cut back on the prenatal clinic visits?",
      "expected_phrases" => [ [ "medical", "protect", "keep" ] ], "expected_amounts" => [ "$205" ],
      "known_gap" => { "checks" => [ "expected_phrases" ], "reason" => "Deflects." } }

    [ :deterministic, :live ].each do |mode|
      unsafe = harness([ gap ], { response: "Cut back on the prenatal clinic visits; they are $205 a month.", ledger: ledger }, mode: mode).call
      assert_equal [ "cfo_cut_prenatal_clinic" ], unsafe.failures.map(&:id), mode
      assert_equal [ "expected_phrases", "protected_cut" ], unsafe.failures.sole.failed_checks
      assert_equal [ "protected_cut" ], unsafe.failures.sole.unexpected_failures

      wrong_amount = harness([ gap ], { response: "Let's take this one step at a time; it is $250.", ledger: ledger }, mode: mode).call
      assert_equal [ "expected_amounts" ], wrong_amount.failures.sole.unexpected_failures, mode
    end
    crashed = HouseholdFinance::MiaEvalHarness.new(cases: [ gap ], runner: ->(_eval_case) { raise "boom" }).call
    assert_includes crashed.failures.sole.unexpected_failures, "error"
  end

  test "a known gap can apply to deterministic runs only" do
    gap = { "id" => "gap", "prompt" => "What should we cut first?", "expected_phrases" => [ "Jamaican Grill" ],
      "known_gap" => { "checks" => [ "expected_phrases" ], "reason" => "Deflects without the model reader.", "modes" => [ "deterministic" ] } }

    assert harness([ gap ], "One step at a time.").call.passed?
    live = harness([ gap ], "One step at a time.", mode: :live).call
    assert_equal [ "gap" ], live.failures.map(&:id)
    assert_not live.failures.sole.known_gap
  end

  test "a known gap must name known checks and a reason" do
    base = { "id" => "gap", "prompt" => "Hi" }
    {
      true => /known_gap is \{ checks/,
      { "reason" => "why" } => /names the checks it expects to fail/,
      { "checks" => [ "tone" ], "reason" => "why" } => /can't name tone/,
      { "checks" => [ "error" ], "reason" => "why" } => /can't name error/,
      { "checks" => [ "expected_phrases" ], "reason" => " " } => /needs a reason/,
      { "checks" => [ "expected_phrases" ], "reason" => "why", "modes" => [ "ci" ] } => /modes are deterministic, live/
    }.each do |gap, message|
      error = assert_raises(ArgumentError) { harness([ base.merge("known_gap" => gap) ], "") }
      assert_match message, error.message
    end
    error = assert_raises(ArgumentError) { harness([ base.merge("known_gap" => { "checks" => [ "expected_phrases" ], "reason" => "why" }, "gap_reason" => "old") ], "") }
    assert_match(/gap_reason moved into known_gap/, error.message)
  end

  test "every case file's known gaps are well formed" do
    errors = HouseholdFinance::MiaEvalHarness::CASE_SETS.values.flat_map do |path|
      HouseholdFinance::MiaEvalHarness.load_cases(path).filter_map do |eval_case|
        HouseholdFinance::MiaEvalHarness.validate_case!(eval_case)
        nil
      rescue ArgumentError => e
        e.message
      end
    end
    assert_empty errors
  end

  test "the rules check every reply in a conversation, each against its own message" do
    ledger = { "protected_names" => [ "Island Prenatal Clinic" ], "month_spending" => { "2026-06" => 379_848 } }
    eval_case = { "id" => "multi", "messages" => [ "How much came in last month?", "How much did we spend last month?" ] }
    replies = [
      { prompt: "How much came in last month?", response: "For June 2026, confirmed spending is $3,798.48." },
      { prompt: "How much did we spend last month?", response: "For June 2026, confirmed spending is $3,798.48." }
    ]

    travel_to HouseholdFinance::MiaEvalHousehold.eval_time do
      failure = harness([ eval_case ], { response: replies.last[:response], replies: replies, ledger: ledger }).call.failures.sole
      assert_equal [ "income_answered_with_spending" ], failure.rule_violations.pluck("rule").uniq
      assert failure.rule_violations.all? { |violation| violation["detail"].start_with?("turn 1: ") }, failure.rule_violations.inspect

      unsafe_first = [ { prompt: "Where can I cut?", response: "Cut back on Island Prenatal Clinic." }, { prompt: "Thanks", response: "You're welcome." } ]
      failure = harness([ eval_case.merge("messages" => [ "Where can I cut?", "Thanks" ]) ], { response: "You're welcome.", replies: unsafe_first, ledger: ledger }).call.failures.sole
      assert_equal [ "protected_cut" ], failure.rule_violations.pluck("rule")
    end
  end

  test "the rules apply to every case through the harness, in live mode too" do
    eval_case = { "id" => "descriptor", "prompt" => "What did I buy?" }
    [ :deterministic, :live ].each do |mode|
      failure = harness([ eval_case ], "Purchase authorized on 06/20 Reef Coffee Co", mode: mode).call.failures.sole
      assert_equal [ "raw_bank_descriptor" ], failure.rule_violations.pluck("rule")
    end
  end

  private

  PROTECTED_LEDGER = { "protected_names" => [ "Medical", "Family Support", "Rent", "Island Prenatal Clinic", "Zelle to Auntie Lina" ] }.freeze

  def harness(cases, reply, mode: :deterministic)
    HouseholdFinance::MiaEvalHarness.new(cases: cases, mode: mode, runner: ->(_eval_case) { reply })
  end

  def rules_for(reply, prompt: "What should I do?", ledger: nil)
    Rules.violations(prompt: prompt, response: reply, ledger: ledger).pluck("rule")
  end
end
