require "test_helper"

# Debts with arrears, using the fictional Talun household: a car loan $1,500 behind and
# a store card that is current. All names and amounts are invented.
class HouseholdFinanceDebtArrearsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "talun_#{SecureRandom.hex(4)}", email: "talun-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @household.update!(name: "Talun household", primary_goal: "Get current on the car loan",
      confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))
    @household.income_sources.create!(label: "Tasi's pay", source_type: "job", amount_cents: 520_000, cadence: "monthly")
    @household.expense_items.create!(label: "Rent and power", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    @household.accounts.create!(label: "Savings", account_type: "emergency_fund", balance_cents: 150_000)
    @car = @household.debts.create!(label: "Car loan", debt_type: "auto_loan", balance_cents: 980_000, minimum_payment_cents: 31_000,
      interest_rate_percent: 6.5, due_day: 15, past_due_cents: 150_000)
    @card = @household.debts.create!(label: "Store card", debt_type: "credit_card", balance_cents: 64_000, minimum_payment_cents: 3_500,
      interest_rate_percent: 29.99)
  end

  test "due day and past-due amount are optional and validated" do
    assert_nil @card.due_day
    assert_nil @card.past_due_cents, "a blank past-due amount stays unknown, never $0"
    refute @card.past_due?

    @card.past_due_cents = 0
    assert @card.valid?
    refute @card.past_due?, "$0 past due is caught up"

    [ 0, 32 ].each do |day|
      @card.due_day = day
      refute @card.valid?, "due day #{day} should be rejected"
    end
    @card.due_day = 31
    @card.past_due_cents = -1
    refute @card.valid?
  end

  test "the database rejects an impossible due day or a negative past-due amount" do
    [ { due_day: 32 }, { due_day: 0 }, { past_due_cents: -100 } ].each do |values|
      assert_raises(ActiveRecord::StatementInvalid, values.inspect) { Debt.transaction(requires_new: true) { @card.update_columns(values) } }
    end
    @card.update_columns(due_day: 1, past_due_cents: 0)
    assert_equal [ 1, 0 ], [ @card.reload.due_day, @card.past_due_cents ]
  end

  test "manual edits save, clear and keep both fields" do
    runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
    runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, due_day: "22", past_due: "95.40" }, idempotency_key: "talun-card-1")
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ]

    runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, balance: "600" }, idempotency_key: "talun-card-2")
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ], "an unrelated edit keeps both"

    runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, due_day: "", past_due: "" }, idempotency_key: "talun-card-3")
    assert_nil @card.reload.due_day
    assert_nil @card.past_due_cents, "clearing the field makes it unknown again, not $0"

    error = assert_raises(ArgumentError) do
      runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, due_day: "40" }, idempotency_key: "talun-card-4")
    end
    assert_match "1 to 31", error.message

    created = runner.run(operation_key: "debt.record.create", input: { label: "Clinic bill plan", debt_type: "medical", balance: "800", past_due: "0", due_day: "5" }, idempotency_key: "talun-clinic")
    assert_equal [ 5, 0 ], [ created.subject.due_day, created.subject.past_due_cents ]
  end

  test "an approved statement balance leaves the due day and past-due amount alone" do
    @car.update!(balance_cents: 900_000)
    assert_equal [ 15, 150_000 ], [ @car.reload.due_day, @car.past_due_cents ]
  end

  test "Home lists the past-due debt with what needs her" do
    dashboard = HouseholdFinance::DataPresenter.new(@household).dashboard
    past_due = dashboard.fetch(:action_center).fetch(:past_due_debts)

    assert_equal [ { id: @car.id, label: "Car loan", past_due_cents: 150_000, due_day: 15, balance_conflict: false } ], past_due
    debt = HouseholdFinance::DataPresenter.new(@household).debt_records.find { |record| record[:id] == @car.id }
    assert_equal 1_500.0, debt.fetch(:past_due)
    assert_equal 15, debt.fetch(:due_day)
    assert_nil HouseholdFinance::DataPresenter.new(@household).debt_records.find { |record| record[:id] == @card.id }.fetch(:past_due)
  end

  test "the debt plan catches up the past-due amount first, then the payoff order" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.", debt_order: "snowball").call

    assert_includes answer, "You are behind on Car loan $1,500 past due (payment due on the 15th)."
    assert_includes answer, "1. Catch up the $1,500 past due first: Car loan $1,500 past due (payment due on the 15th). 2. Protect essential bills"
    assert_includes answer, "Snowball: Store card first"
    # Hand check: $5,200 income - $3,000 essentials - $345 minimums = $1,855 surplus.
    # $1,855 - $1,500 catch-up = $355; the Store card cap is $640 - $35 = $605, so $355.
    assert_includes answer, "up to $355"
    assert_includes answer, "Snowball and avalanche apply to extra payments after the past-due amounts are caught up."
    assert_operator answer.index("You are behind"), :<, answer.index("Snowball:")
  end

  test "a catch-up larger than the surplus holds extra principal" do
    @car.update!(past_due_cents: 250_000)
    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.", debt_order: "avalanche").call

    assert_includes answer, "1. Catch up the $2,500 past due first"
    assert_includes answer, "3. Hold extra principal until the past-due amounts are caught up; this month's $1,855 surplus does not cover all of it."
    refute_includes answer, "up to $"
  end

  test "what should I pay first answers with the past-due amount, then the program's order" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, "What should I pay first?").call

    assert answer.start_with?("Catch up what you are behind on first: Car loan $1,500 past due (payment due on the 15th)."), answer
    assert_includes answer, "keep every other minimum current"
    assert_includes answer, "After you are caught up, extra payments go to Store card first: it is both the smallest balance (snowball) and the highest APR (avalanche)."

    @household.debts.create!(label: "Clinic plan", debt_type: "medical", balance_cents: 30_000, minimum_payment_cents: 2_500, interest_rate_percent: 0)
    split = HouseholdFinance::MiaCoachAnswerer.new(@household, "What should I pay first?").call
    assert_includes split, "After you are caught up, extra payments follow your payoff order: avalanche (highest APR first) starts with Store card, or snowball (smallest balance first) starts with Clinic plan."
    assert_includes answer, "No payment is made automatically."
  end

  test "with nothing past due the bill answer is unchanged and a blank amount is not treated as behind" do
    @car.update!(past_due_cents: nil)
    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, "What should I pay first?").call
    refute_includes answer, "past due"
    assert_includes answer, "Start with the bill that protects the household baseline first."
    assert_empty HouseholdFinance::DebtArrears.new(@household).debts
  end

  test "Mia's context gives each debt's due day and past-due amount, unknown kept blank" do
    debts = HouseholdFinance::MiaContextBuilder.new(@household).send(:debt_context)
    records = debts.fetch(:records).index_by { |record| record[:label] }

    assert_equal [ 15, "$1,500" ], records.fetch("Car loan").values_at(:due_day, :past_due)
    assert_nil records.fetch("Store card")[:past_due]
    assert_includes debts.fetch(:unavailable_fields), "due_date", "an exact next due date is never recorded"
    assert_includes debts.fetch(:unavailable_fields), "due_day", "the Store card has no due day"

    @card.update!(due_day: 3)
    fields = HouseholdFinance::MiaContextBuilder.new(@household).send(:debt_context).fetch(:unavailable_fields)
    assert_includes fields, "due_date", "a recurring due day is not an exact due date"
    refute_includes fields, "due_day"

    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 1_000_000, debt_summary_balance_known: true,
      debt_summary_minimum_payment_cents: 34_500, debt_summary_minimum_payment_known: true)
    summary = HouseholdFinance::MiaContextBuilder.new(@household).send(:debt_context)
    assert_empty summary.fetch(:records)
    assert_equal %w[due_day due_date], summary.fetch(:unavailable_fields) & %w[due_day due_date], "no canonical rows means neither is known"
    assert_equal "Car loan", debts.dig(:past_due, :debts, 0, :label)
    assert_match "comes first", debts.dig(:past_due, :rule)
  end

  test "Mia prepares a past-due and due-day update that changes nothing until she applies it" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
    result = HouseholdFinance::MiaActionDraftBuilder.new(@household, user: @user, annual_budget_manager: manager,
      raw_input: "model resolved debt command", command: { type: "update_debt", debt_id: @card.id, past_due: "95.40", due_day: "22nd" }).call

    assert_includes result.proposal.summary, "$95.40 past due"
    assert_includes result.proposal.summary, "payment due on the 22nd"
    assert_nil @card.reload.past_due_cents

    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    draft = result.proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: "I'm $95.40 behind on the Store card, due on the 22nd"),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this change")
    )
    review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields)
    assert_equal({ label: "Past due", before: "Not entered", after: "$95.40" }, review.find { |field| field[:label] == "Past due" })
    assert_equal({ label: "Payment due day", before: "Not entered", after: "The 22nd of each month" }, review.find { |field| field[:label] == "Payment due day" })

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ]
  end

  test "a Mia create card prepared before due day and past due existed still applies" do
    draft = mia_draft(type: "create_debt", debt_name: "Clinic plan", debt_type: "medical", balance: "800", minimum_payment: "40")
    make_pre_deploy!(draft.mia_action_items.sole)

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft.reload, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    clinic = @household.debts.find_by!(label: "Clinic plan")
    assert_equal [ 80_000, nil, nil ], [ clinic.balance_cents, clinic.due_day, clinic.past_due_cents ]
  end

  test "a Mia update card prepared before due day and past due existed still applies, and a changed value still makes it stale" do
    draft = mia_draft(type: "update_debt", debt_id: @card.id, debt_name: "Store card", amount: "600")
    make_pre_deploy!(draft.mia_action_items.sole)

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft.reload, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    assert_equal [ 60_000, nil, nil ], [ @card.reload.balance_cents, @card.due_day, @card.past_due_cents ]

    stale = mia_draft(type: "update_debt", debt_id: @card.id, debt_name: "Store card", amount: "550")
    make_pre_deploy!(stale.mia_action_items.sole)
    @card.update!(past_due_cents: 3_500)
    refused = HouseholdFinance::MiaActionDraftApplier.new(stale.reload, user: @user).call
    refute refused.success?, "a past-due amount entered since the card was drafted makes it stale"
    assert_equal 60_000, @card.reload.balance_cents
  end

  test "a current Mia arrears card applies once and a retry replays it" do
    draft = mia_draft(type: "update_debt", debt_id: @card.id, debt_name: "Store card", past_due: "95.40", due_day: "22")
    first = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert first.success?, first.errors.to_sentence
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ]

    item = draft.reload.mia_action_items.sole
    replay = HouseholdFinance::Operations::Runner.new(@household, user: @user).run_prepared(
      prepared: item.prepared_operation, prepared_fingerprint: item.prepared_operation_fingerprint,
      idempotency_key: "mia-action-item:#{item.id}", source: "mia", reviewable: item
    )
    assert replay.replayed?
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ]
  end

  test "applying a rename-only plan keeps both debts' past-due amounts and due days" do
    @card.update!(past_due_cents: 0, due_day: 5)
    message = "Rename Car loan to Truck loan and rename Store card to Blue Card"
    clears = { past_due: "unknown", due_day: "unknown" }
    draft = mia_draft({ type: "compound_action_plan", actions: [
      { source_text: "Rename Car loan to Truck loan", depends_on: [], action: { type: "update_debt", debt_id: @car.id, debt_name: "Car loan", new_name: "Truck loan", **clears } },
      { source_text: "rename Store card to Blue Card", depends_on: [], action: { type: "update_debt", debt_id: @card.id, debt_name: "Store card", new_name: "Blue Card", **clears } }
    ] }, raw_input: message)

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    assert_equal [ "Truck loan", 15, 150_000 ], [ @car.reload.label, @car.due_day, @car.past_due_cents ]
    assert_equal [ "Blue Card", 5, 0 ], [ @card.reload.label, @card.due_day, @card.past_due_cents ]
  end

  test "a debt the catch-up pays off is not the target for extra principal" do
    # Visa: $100 balance, all of it past due. Catching up pays it off.
    visa = @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 10_000, minimum_payment_cents: 2_500,
      interest_rate_percent: 35.0, past_due_cents: 10_000)
    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.", debt_order: "both").call

    assert_includes answer, "Catching up Visa pays off its $100 balance, so its $25 minimum is not owed on top."
    assert_includes answer, "($345 total across the debts listed)", "Visa's minimum is not counted on top of its catch-up"
    # Hand check: $5,200 - $3,000 - $370 minimums = $1,830 surplus; - $1,600 catch-up + $25
    # Visa minimum not owed = $255 for extra principal, under the Store card's $605 cap.
    assert_includes answer, "up to $255 from the current monthly surplus to Store card"
    refute_match(/(?:Avalanche|Snowball): Visa first/, answer)
    refute_match(/up to \$[\d,]+ to Visa/, answer)
    assert_includes answer, "Avalanche: Store card first", "the highest APR left after the catch-up"

    first = HouseholdFinance::DebtStrategyPlanner.new(@household, "What should I pay first?", debt_order: "both").arrears_first_answer
    refute_includes first, "extra payments go to Visa"
    refute_match(/starts with Visa/, first)
    assert visa.reload.past_due?
  end

  test "a refund covers the catch-up before any principal when the monthly surplus cannot" do
    # Hand check: $5,200 income - $3,000 essentials - $345 minimums = $1,855 surplus.
    # $5,000 of new essentials makes it -$3,145, so none of the $1,500 catch-up is funded.
    @household.expense_items.create!(label: "Clinic stay", stack_key: "non_discretionary", amount_cents: 500_000, cadence: "monthly")
    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "I have a $50 refund. Should I use it on debt? Give me a debt plan.", debt_order: "avalanche").call

    assert_includes answer, "Put the whole $50 toward the past-due amounts first."
    assert_includes answer, "That still leaves $1,450 past due, so none of it goes to extra principal."
    refute_includes answer, "avalanche targets"
    assert_includes answer, "3. Hold extra principal until the past-due amounts are caught up."
    assert_includes answer, "The $50 one-time amount goes to the catch-up first, as above."
  end

  test "a refund left after the catch-up covers a monthly shortfall, never extra principal" do
    # Hand check: $5,200 income - $3,000 essentials - $345 minimums = $1,855 surplus.
    # $1,955 of new essentials makes it -$100. The $160 refund covers the $150 catch-up,
    # and the $10 left goes to the shortfall, matching the numbered plan.
    @household.expense_items.create!(label: "Clinic stay", stack_key: "non_discretionary", amount_cents: 195_500, cadence: "monthly")
    @car.update!(past_due_cents: 15_000)
    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "I have a $160 refund. Should I use it on debt? Give me a debt plan.", debt_order: "avalanche").call

    assert_includes answer, "Put $150 of the $160 toward the past-due amounts first; that covers the rest of the catch-up."
    assert_includes answer, "This month's plan runs $100 short, so keep the remaining $10 for essential bills and minimums; none of it goes to extra principal"
    refute_includes answer, "avalanche targets"
    refute_includes answer, "Store card first"
    refute_includes answer, "Car loan first"
    assert_includes answer, "once the monthly shortfall is covered"
    refute_includes answer, "After that guardrail"
    assert_includes answer, "3. Hold extra principal until the past-due amounts are caught up."
    assert_includes answer, "The remaining $10 stays for essential bills and minimums while the monthly baseline is $100 short."
  end

  test "a past-due amount above a $0 balance is a records problem, never debt-free" do
    @car.destroy!
    @card.update!(balance_cents: 0, minimum_payment_cents: 0, past_due_cents: 4_000)
    planner = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.")

    refute planner.confirmed_debt_free?
    answer = planner.call
    assert_includes answer, "Your debt records do not add up yet: Store card shows $40 past due but a $0 balance."
    refute_includes answer, "no outstanding debt"
    refute_match(/up to \$/, answer)
    assert_nil HouseholdFinance::MiaCoachAnswerer.new(@household, "Give me a debt plan.").send(:confirmed_debt_free_answer)
    assert HouseholdFinance::DataPresenter.new(@household).dashboard.dig(:action_center, :past_due_debts, 0, :balance_conflict)
  end

  test "an overdue debt under a $0 approved summary is surfaced, not called debt-free" do
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 0, debt_summary_balance_known: true,
      debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: true)
    planner = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.")

    refute planner.confirmed_debt_free?
    answer = planner.call
    assert_includes answer, "your approved debt summary shows $0 owed in all, less than the $1,500 past due"
    refute_includes answer, "no outstanding debt"
  end

  test "the CFO Filter and windfall split check your debts when a $0 summary sits under a past-due card" do
    @car.destroy!
    @card.update!(past_due_cents: 15_000)
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 0, debt_summary_balance_known: true,
      debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: true)
    presenter = HouseholdFinance::DataPresenter.new(@household)

    scenario = presenter.cfo_filter_scenario(windfall_cents: 10_000_000)
    assert_nil scenario.dig(:before, :debt_months), "no payoff estimate while the records disagree"
    assert_nil scenario.dig(:before, :debt_tone)
    assert_equal 15_000, scenario.fetch(:catch_up_cents), "the known past-due amount is still owed now"
    assert_includes scenario.fetch(:debt_records_conflict).join, "less than the $150 past due"
    assert_equal 15_000, scenario.fetch(:windfall).find { |step| step[:key] == "consumer_debt_catch_up" }&.fetch(:cents)
    debt_step = scenario.fetch(:windfall).find { |step| step[:key] == "consumer_debt" }
    assert debt_step, scenario.fetch(:windfall).inspect
    refute debt_step[:room_known], "the rest waits on her checking her debts, never treated as $0 owed"
    refute(scenario.fetch(:windfall).any? { |step| step[:key] == "surplus" })
    assert_nil HouseholdFinance::WindfallSplit.consumer_debt_cents(@household)
    windfall_reply = HouseholdFinance::MiaCoachAnswerer.new(@household, "Where should a $500 windfall go?").send(:windfall_line, 50_000)
    assert_includes windfall_reply, "Your debt records do not add up yet"
    assert_includes windfall_reply, "Check your debts before any extra principal goes to debt."
    refute_includes windfall_reply, "before any of it goes to debt."

    filter = presenter.cfo_filter
    extra = filter.fetch(:decisions).find { |decision| decision[:item] == "Extra debt payment" }
    assert_equal "Wait", extra[:recommendation]
    assert_match(/\AYour debt records do not add up yet: .*Check your debts/, extra[:reason])
    refute_match(/\ANo debt entered yet/, extra[:reason])
    assert_equal [ "Check your debts" ], filter.fetch(:targets).pluck(:label).grep(/debt/i)
  end

  test "a statement balance below the past-due amount keeps both fields and flags the conflict" do
    offer = { "kind" => "debt", "key" => "a" * 64, "tracked_account_id" => 41, "identity_version_id" => 1, "revision_approval_id" => 1,
      "as_of_on" => "2026-11-30", "statement_label" => "Talun Auto ····2210", "balance_cents" => 100_000,
      "choices" => [ { "id" => @car.id } ], "target" => nil, "can_add_new" => false }
    # The approved statement's offer, without building a statement import here.
    operation = Class.new(HouseholdFinance::Operations::Debt::StatementBalanceApply) { define_method(:current_offer) { |_input| offer } }.new(@household)
    input = { tracked_account_id: 41, offer_key: "a" * 64, debt_id: @car.id }
    prepared = operation.prepare(input)
    assert_equal [ 15, 150_000 ], prepared.predicted_after_snapshot.fetch("debt").values_at("due_day", "past_due_cents")
    Debt.transaction { operation.execute!(prepared, source: "manual_ui") }
    assert_equal [ 100_000, 15, 150_000 ], [ @car.reload.balance_cents, @car.due_day, @car.past_due_cents ]
    assert HouseholdFinance::DebtArrears.new(@household).conflict?
    assert_includes HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.").call, "Car loan shows $1,500 past due but a $1,000 balance"
  end

  test "the CFO filter and Mia's windfall answer catch up card and loan arrears first, never the mortgage" do
    @household.debts.create!(label: "Talun home loan", debt_type: "mortgage", balance_cents: 25_000_000, minimum_payment_cents: 140_000,
      interest_rate_percent: 6.0, past_due_cents: 280_000)
    scenario = HouseholdFinance::DataPresenter.new(@household).send(:cfo_filter_scenario, windfall_cents: 5_000_000)
    assert_equal 150_000, scenario.fetch(:catch_up_cents), "the mortgage's arrears are not consumer catch-up"
    steps = scenario.fetch(:windfall).to_h { |step| [ step[:key], step[:cents] ] }
    assert_equal 150_000, steps.fetch("consumer_debt_catch_up")
    assert_equal %w[emergency_fund consumer_debt_catch_up consumer_debt], steps.keys.first(3)
    assert_equal 980_000 + 64_000 - 150_000, steps.fetch("consumer_debt"), "principal room is what is left of the same balances"

    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, "I got a $1,000 bonus").send(:windfall_line, 100_000)
    assert_includes answer, "catching up the $1,500 past due before any extra principal"

    # Summary mode: the total is unknown, but the known arrears are still reported.
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 2_600_000, debt_summary_balance_known: true,
      debt_summary_minimum_payment_cents: 175_000, debt_summary_minimum_payment_known: true)
    split = HouseholdFinance::WindfallSplit.new(amount_cents: 200_000, order: %w[consumer_debt emergency_fund surplus], emergency_fund_gap_cents: 0,
      consumer_debt_cents: HouseholdFinance::WindfallSplit.consumer_debt_cents(@household.reload),
      catch_up_cents: HouseholdFinance::WindfallSplit.consumer_catch_up_cents(@household)).call
    assert_equal [ { key: "consumer_debt_catch_up", cents: 150_000, room_known: true }, { key: "consumer_debt", cents: 50_000, room_known: false } ], split
  end

  private

  def mia_draft(command = nil, raw_input: "model resolved debt command", **fields)
    command ||= fields
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
    result = HouseholdFinance::MiaActionDraftBuilder.new(@household, user: @user, annual_budget_manager: manager,
      raw_input: raw_input, command: command).call
    assert result.proposal, result.response
    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    result.proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: "Please update my debt"),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this change")
    )
  end

  # Rewrites a card the way it was stored before the two debt fields existed.
  def make_pre_deploy!(item)
    legacy_keys = %w[due_day past_due_cents]
    strip = ->(value) { value.is_a?(Hash) ? value.except(*legacy_keys) : value }
    prepared = item.prepared_operation.deep_dup
    prepared["normalized_input"] = strip.call(prepared["normalized_input"])
    %w[before_snapshot predicted_after_snapshot].each do |key|
      prepared[key]["debt"] = strip.call(prepared[key]["debt"]) if prepared[key]["debt"]
    end
    prepared["before_fingerprint"] = HouseholdFinance::Operations::PreparedOperation.fingerprint(prepared["before_snapshot"])
    item.update_columns(
      payload: strip.call(item.payload), before_snapshot: strip.call(item.before_snapshot), after_snapshot: strip.call(item.after_snapshot),
      prepared_operation: prepared, prepared_operation_fingerprint: HouseholdFinance::Operations::PreparedOperation.from_hash(prepared).fingerprint
    )
    refute item.reload.prepared_operation.fetch("normalized_input").key?("past_due_cents")
  end
end
